#import "NDPerf.h"
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

typedef CFDictionaryRef (*NDIOCopyChannels_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*NDIOMerge_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef void *(*NDIOSub_t)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*NDIOSample_t)(void *, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*NDIODelta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*NDIOChStr_t)(CFDictionaryRef);
typedef int32_t (*NDIOStateCnt_t)(CFDictionaryRef);
typedef CFStringRef (*NDIOStateName_t)(CFDictionaryRef, int32_t);
typedef int64_t (*NDIOStateRes_t)(CFDictionaryRef, int32_t);

static struct {
    NDIOCopyChannels_t copyChannels;
    NDIOMerge_t mergeChannels;
    NDIOSub_t createSub;
    NDIOSample_t createSample;
    NDIODelta_t createDelta;
    NDIOChStr_t channelGroup;
    NDIOChStr_t channelName;
    NDIOStateCnt_t stateCount;
    NDIOStateName_t stateName;
    NDIOStateRes_t stateResidency;
} gIO;

static void *gSubscription = NULL;
static CFMutableDictionaryRef gSubChannels = NULL;
static CFDictionaryRef gPrevSample = NULL;
static uint32_t *gECpuMHz = NULL;
static uint32_t *gPCpuMHz = NULL;
static uint32_t *gGPUMHz = NULL;
static int gECpuCount = 0;
static int gPCpuCount = 0;
static int gGPUCount = 0;
static unsigned int gCpuMHz = 0;
static unsigned int gGpuMHz = 0;
static bool gPerfReady = NO;

static void *NDLoadIO(const char *sym) {
    return dlsym(RTLD_DEFAULT, sym);
}

static BOOL NDLoadIOSymbols(void) {
    gIO.copyChannels = NDLoadIO("IOReportCopyChannelsInGroup");
    gIO.mergeChannels = NDLoadIO("IOReportMergeChannels");
    gIO.createSub = NDLoadIO("IOReportCreateSubscription");
    gIO.createSample = NDLoadIO("IOReportCreateSamples");
    gIO.createDelta = NDLoadIO("IOReportCreateSamplesDelta");
    gIO.channelGroup = NDLoadIO("IOReportChannelGetGroup");
    gIO.channelName = NDLoadIO("IOReportChannelGetChannelName");
    gIO.stateCount = NDLoadIO("IOReportStateGetCount");
    gIO.stateName = NDLoadIO("IOReportStateGetNameForIndex");
    gIO.stateResidency = NDLoadIO("IOReportStateGetResidency");
    return gIO.copyChannels && gIO.mergeChannels && gIO.createSub && gIO.createSample
        && gIO.createDelta && gIO.channelGroup && gIO.channelName && gIO.stateCount
        && gIO.stateName && gIO.stateResidency;
}

static void NDToMHz(const uint32_t *raw, int count, uint32_t **out, int *outCount) {
    if (count <= 0) {
        *out = NULL;
        *outCount = 0;
        return;
    }
    uint32_t max = 0;
    for (int i = 0; i < count; i++)
        if (raw[i] > max) max = raw[i];
    uint32_t div = (max > 100000) ? 1000000u : (max > 1000 ? 1000u : 1u);

    uint32_t *mhz = calloc((size_t)count, sizeof(uint32_t));
    int n = 0;
    for (int i = 0; i < count; i++) {
        if (!raw[i]) continue;
        mhz[n++] = raw[i] / div;
    }
    *out = mhz;
    *outCount = n;
}

static void NDPickDvfsTables(CFArrayRef tables, uint32_t **ecpu, int *ecpuN,
                             uint32_t **pcpu, int *pcpuN, uint32_t **gpu, int *gpuN) {
    typedef struct { const char *key; uint32_t *mhz; int count; int maxMHz; int isSram; } Table;
    enum { kMaxTables = 32 };
    Table list[kMaxTables];
    int nTables = 0;

    for (CFIndex i = 0; i < CFArrayGetCount(tables) && nTables < kMaxTables; i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(tables, i);
        CFStringRef keyRef = CFDictionaryGetValue(item, CFSTR("key"));
        CFDataRef data = CFDictionaryGetValue(item, CFSTR("data"));
        if (!keyRef || !data) continue;

        char key[128] = {0};
        if (!CFStringGetCString(keyRef, key, sizeof(key), kCFStringEncodingUTF8)) continue;
        if (strncmp(key, "voltage-states", 14) != 0) continue;

        const UInt8 *bytes = CFDataGetBytePtr(data);
        CFIndex len = CFDataGetLength(data);
        if (len < 16) continue;

        uint32_t raw[64];
        int pairs = (int)(len / 8);
        int cnt = 0;
        for (int j = 0; j < pairs && cnt < 64; j++) {
            uint32_t f = (uint32_t)bytes[j * 8] | ((uint32_t)bytes[j * 8 + 1] << 8)
                       | ((uint32_t)bytes[j * 8 + 2] << 16) | ((uint32_t)bytes[j * 8 + 3] << 24);
            if (f) raw[cnt++] = f;
        }
        if (cnt < 2) continue;

        uint32_t *mhz = NULL;
        int mhzN = 0;
        NDToMHz(raw, cnt, &mhz, &mhzN);
        if (!mhz || mhzN < 2) {
            free(mhz);
            continue;
        }

        list[nTables].key = strdup(key);
        list[nTables].mhz = mhz;
        list[nTables].count = mhzN;
        list[nTables].maxMHz = (int)mhz[mhzN - 1];
        list[nTables].isSram = (strstr(key, "-sram") != NULL);
        nTables++;
    }

    int pMax = 0, pIdx = -1;
    for (int i = 0; i < nTables; i++) {
        if (!list[i].isSram || list[i].maxMHz <= 2000) continue;
        if (list[i].maxMHz > pMax) {
            pMax = list[i].maxMHz;
            pIdx = i;
        }
    }
    if (pIdx >= 0) {
        *pcpu = list[pIdx].mhz;
        *pcpuN = list[pIdx].count;
        list[pIdx].mhz = NULL;
    }

    int eMax = 0, eIdx = -1;
    for (int i = 0; i < nTables; i++) {
        if (!list[i].mhz || !list[i].isSram) continue;
        if (list[i].maxMHz > 500 && list[i].maxMHz < pMax && list[i].count > 2) {
            if (list[i].maxMHz > eMax) {
                eMax = list[i].maxMHz;
                eIdx = i;
            }
        }
    }
    if (eIdx >= 0) {
        *ecpu = list[eIdx].mhz;
        *ecpuN = list[eIdx].count;
        list[eIdx].mhz = NULL;
    }

    int gMax = 0, gIdx = -1;
    for (int i = 0; i < nTables; i++) {
        if (!list[i].mhz || list[i].isSram) continue;
        if (list[i].maxMHz >= 300 && list[i].maxMHz <= 5000 && list[i].count >= 3) {
            if (list[i].count > gMax) {
                gMax = list[i].count;
                gIdx = i;
            }
        }
    }
    if (gIdx < 0) {
        for (int i = 0; i < nTables; i++) {
            if (!list[i].mhz || !list[i].isSram) continue;
            if (list[i].maxMHz >= 300 && list[i].maxMHz <= 5000 && list[i].count >= 3) {
                if (list[i].count > gMax) {
                    gMax = list[i].count;
                    gIdx = i;
                }
            }
        }
    }
    if (gIdx >= 0) {
        *gpu = list[gIdx].mhz;
        *gpuN = list[gIdx].count;
        list[gIdx].mhz = NULL;
    }

    for (int i = 0; i < nTables; i++) {
        free(list[i].mhz);
        free((void *)list[i].key);
    }
}

static CFMutableArrayRef NDReadDvfsTables(void) {
    CFMutableArrayRef tables = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) != KERN_SUCCESS)
        return tables;

    io_registry_entry_t entry;
    while ((entry = IOIteratorNext(iter))) {
        char name[128] = {0};
        if (IORegistryEntryGetName(entry, name) != KERN_SUCCESS || strcmp(name, "pmgr") != 0) {
            IOObjectRelease(entry);
            continue;
        }

        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFIndex count = CFDictionaryGetCount(props);
            const void **keys = calloc((size_t)count, sizeof(void *));
            const void **vals = calloc((size_t)count, sizeof(void *));
            CFDictionaryGetKeysAndValues(props, keys, vals);
            for (CFIndex i = 0; i < count; i++) {
                char key[128] = {0};
                if (!CFStringGetCString((CFStringRef)keys[i], key, sizeof(key), kCFStringEncodingUTF8)) continue;
                if (strncmp(key, "voltage-states", 14) != 0) continue;
                if (CFGetTypeID((CFTypeRef)vals[i]) != CFDataGetTypeID()) continue;

                CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                        &kCFTypeDictionaryValueCallBacks);
                CFDictionarySetValue(item, CFSTR("key"), keys[i]);
                CFDictionarySetValue(item, CFSTR("data"), vals[i]);
                CFArrayAppendValue(tables, item);
                CFRelease(item);
            }
            free(keys);
            free(vals);
            CFRelease(props);
        }
        IOObjectRelease(entry);
        break;
    }
    IOObjectRelease(iter);
    return tables;
}

static int NDStateOffset(CFDictionaryRef ch) {
    int32_t count = gIO.stateCount(ch);
    for (int32_t s = 0; s < count; s++) {
        char name[32] = {0};
        CFStringRef nm = gIO.stateName(ch, s);
        if (!nm || !CFStringGetCString(nm, name, sizeof(name), kCFStringEncodingUTF8)) continue;
        if (strcmp(name, "IDLE") && strcmp(name, "DOWN") && strcmp(name, "OFF"))
            return (int)s;
    }
    return count > 2 ? 2 : 0;
}

static void NDAccumResidency(CFDictionaryRef ch, int offset, uint64_t *residency, int cap) {
    int32_t count = gIO.stateCount(ch);
    for (int32_t s = offset; s < count; s++) {
        int64_t r = gIO.stateResidency(ch, s);
        if (r <= 0) continue;
        int idx = (int)(s - offset);
        if (idx >= 0 && idx < cap)
            residency[idx] += (uint64_t)r;
    }
}

static unsigned int NDCalcMHz(const uint64_t *residency, int cap, const uint32_t *freqs, int freqCount) {
    if (!freqs || freqCount <= 0) return 0;
    uint64_t total = 0;
    double weighted = 0;
    for (int i = 0; i < cap; i++) {
        if (!residency[i]) continue;
        uint32_t mhz = (i < freqCount) ? freqs[i] : freqs[freqCount - 1];
        total += residency[i];
        weighted += (double)mhz * (double)residency[i];
    }
    if (total == 0) return 0;
    return (unsigned int)llround(weighted / (double)total);
}

static BOOL NDStartsWith(const char *s, const char *prefix) {
    size_t n = strlen(prefix);
    return strncmp(s, prefix, n) == 0;
}

static void NDProcessDelta(CFDictionaryRef delta) {
    CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (!channels) return;

    int pCap = gPCpuCount > 0 ? gPCpuCount : 32;
    int eCap = gECpuCount > 0 ? gECpuCount : 32;
    int gCap = gGPUCount > 0 ? gGPUCount : 32;
    uint64_t *pRes = calloc((size_t)pCap, sizeof(uint64_t));
    uint64_t *eRes = calloc((size_t)eCap, sizeof(uint64_t));
    uint64_t *gRes = calloc((size_t)gCap, sizeof(uint64_t));

    CFIndex n = CFArrayGetCount(channels);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(channels, i);
        char group[64] = {0}, name[64] = {0};
        CFStringGetCString(gIO.channelGroup(ch), group, sizeof(group), kCFStringEncodingUTF8);
        CFStringGetCString(gIO.channelName(ch), name, sizeof(name), kCFStringEncodingUTF8);
        int offset = NDStateOffset(ch);

        if (strcmp(group, "CPU Stats") == 0) {
            if (NDStartsWith(name, "PCPU"))
                NDAccumResidency(ch, offset, pRes, pCap);
            else if (NDStartsWith(name, "ECPU") || NDStartsWith(name, "MCPU"))
                NDAccumResidency(ch, offset, eRes, eCap);
            continue;
        }
        if (strcmp(group, "GPU Stats") == 0) {
            NDAccumResidency(ch, offset, gRes, gCap);
        }
    }

    gCpuMHz = NDCalcMHz(pRes, pCap, gPCpuMHz, gPCpuCount);
    if (gCpuMHz == 0)
        gCpuMHz = NDCalcMHz(eRes, eCap, gECpuMHz, gECpuCount);
    gGpuMHz = NDCalcMHz(gRes, gCap, gGPUMHz, gGPUCount);

    free(pRes);
    free(eRes);
    free(gRes);
}

bool NDPerfInit(void) {
    if (gPerfReady) return YES;
    if (!NDLoadIOSymbols()) return NO;

    CFMutableArrayRef tables = NDReadDvfsTables();
    NDPickDvfsTables(tables, &gECpuMHz, &gECpuCount, &gPCpuMHz, &gPCpuCount, &gGPUMHz, &gGPUCount);
    if (tables) CFRelease(tables);
    if (gPCpuCount <= 0 && gECpuCount <= 0 && gGPUCount <= 0) return NO;

    CFDictionaryRef cpu = gIO.copyChannels(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    CFDictionaryRef gpu = gIO.copyChannels(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    if (!cpu || !gpu) {
        if (cpu) CFRelease(cpu);
        if (gpu) CFRelease(gpu);
        return NO;
    }
    gIO.mergeChannels(cpu, gpu, NULL);
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(NULL, 0, cpu);
    CFRelease(cpu);
    CFRelease(gpu);
    if (!desired) return NO;

    gSubChannels = NULL;
    gSubscription = gIO.createSub(NULL, desired, &gSubChannels, 0, NULL);
    CFRelease(desired);
    if (!gSubscription || !gSubChannels) return NO;

    gPerfReady = YES;
    return YES;
}

void NDPerfTick(void) {
    if (!gPerfReady) return;

    CFDictionaryRef cur = gIO.createSample(gSubscription, gSubChannels, NULL);
    if (!cur) return;

    if (!gPrevSample) {
        gPrevSample = cur;
        return;
    }

    CFDictionaryRef delta = gIO.createDelta(gPrevSample, cur, NULL);
    CFRelease(gPrevSample);
    gPrevSample = cur;
    if (!delta) return;

    NDProcessDelta(delta);
    CFRelease(delta);
}

bool NDPerfCPUMHz(unsigned int *mhzOut) {
    if (!gPerfReady || gCpuMHz == 0) return NO;
    if (mhzOut) *mhzOut = gCpuMHz;
    return YES;
}

bool NDPerfGPUMHz(unsigned int *mhzOut) {
    if (!gPerfReady || gGpuMHz == 0) return NO;
    if (mhzOut) *mhzOut = gGpuMHz;
    return YES;
}
