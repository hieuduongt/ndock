#import "NDStats.h"
#import "NDPerf.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <mach/mach.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/route.h>
#import <dispatch/dispatch.h>

static CATextLayer *gDiskLayer = NULL;
static CATextLayer *gRamLayer = NULL;
static CATextLayer *gChipLayer = NULL;
static CATextLayer *gNetUpLayer = NULL;
static CATextLayer *gNetDownLayer = NULL;

static dispatch_source_t gStatsTimer = NULL;
static BOOL gStatsStarted = NO;

static uint64_t gPrevNetIn = 0;
static uint64_t gPrevNetOut = 0;
static CFAbsoluteTime gPrevNetTime = 0;
static BOOL gHasNetSample = NO;

static CFAbsoluteTime gLastLayoutTick = 0;
static BOOL gVerticalCompact = NO;

static NSString *NDFormatBytes(uint64_t bytes) {
    const double gb = (double)bytes / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 10.0) return [NSString stringWithFormat:@"%.0f GB", gb];
    if (gb >= 1.0) return [NSString stringWithFormat:@"%.1f GB", gb];
    const double mb = (double)bytes / (1024.0 * 1024.0);
    return [NSString stringWithFormat:@"%.0f MB", mb];
}

static NSString *NDFormatDiskGB(uint64_t bytes) {
    const double gb = (double)bytes / (1000.0 * 1000.0 * 1000.0);
    if (gb >= 100.0) return [NSString stringWithFormat:@"%.0fGB", gb];
    if (gb >= 10.0) return [NSString stringWithFormat:@"%.0fGB", gb];
    return [NSString stringWithFormat:@"%.1fGB", gb];
}

static NSString *NDFormatDiskVertical(uint64_t bytes) {
    const double gb = (double)bytes / (1000.0 * 1000.0 * 1000.0);
    if (gb >= 100.0) return [NSString stringWithFormat:@"%.0fG", gb];
    if (gb >= 10.0) return [NSString stringWithFormat:@"%.0fG", gb];
    return [NSString stringWithFormat:@"%.1fG", gb];
}

static NSString *NDFormatRate(double bps) {
    if (bps < 1.0) return @"0 B/s";
    if (bps < 1024.0) return [NSString stringWithFormat:@"%.0f B/s", bps];
    if (bps < 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.1f KB/s", bps / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB/s", bps / (1024.0 * 1024.0)];
}

static NSString *NDFormatBytesShort(uint64_t bytes) {
    const double gb = (double)bytes / (1024.0 * 1024.0 * 1024.0);
    if (gb >= 10.0) return [NSString stringWithFormat:@"%.0fG", gb];
    if (gb >= 1.0) return [NSString stringWithFormat:@"%.1fG", gb];
    const double mb = (double)bytes / (1024.0 * 1024.0);
    return [NSString stringWithFormat:@"%.0fM", mb];
}

static NSString *NDFormatRateShort(double bps) {
    if (bps < 1.0) return @"0";
    if (bps < 1024.0) return [NSString stringWithFormat:@"%.0fB", bps];
    if (bps < 1024.0 * 1024.0) return [NSString stringWithFormat:@"%.0fK", bps / 1024.0];
    return [NSString stringWithFormat:@"%.1fM", bps / (1024.0 * 1024.0)];
}

static NSString *NDFormatClockVertical(unsigned int mhz) {
    if (mhz >= 1000)
        return [NSString stringWithFormat:@"%.1fG", mhz / 1000.0];
    return [NSString stringWithFormat:@"%uM", mhz];
}

static NSString *NDFormatClockMHz(unsigned int mhz) {
    if (mhz >= 1000)
        return [NSString stringWithFormat:@"%.1fGHz", mhz / 1000.0];
    return [NSString stringWithFormat:@"%uMHz", mhz];
}

static BOOL NDDiskUsage(uint64_t *usedOut, uint64_t *totalOut, unsigned int *usedPctOut) {
    struct statfs s = {0};
    if (statfs("/", &s) != 0) return NO;
    uint64_t total = (uint64_t)s.f_blocks * s.f_bsize;
    uint64_t free = (uint64_t)s.f_bavail * s.f_bsize;
    if (total == 0) return NO;
    uint64_t used = total - free;
    *usedOut = used;
    *totalOut = total;
    *usedPctOut = (unsigned int)((used * 100ULL) / total);
    return YES;
}

static BOOL NDRamUsage(uint64_t *usedOut, uint64_t *totalOut) {
    int64_t memsize = 0;
    size_t sz = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &sz, NULL, 0) != 0 || memsize <= 0)
        return NO;

    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);

    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&vm, &count) != KERN_SUCCESS)
        return NO;

    uint64_t used = ((uint64_t)vm.active_count + vm.wire_count + vm.compressor_page_count)
                     * pageSize;
    *usedOut = used;
    *totalOut = (uint64_t)memsize;
    return YES;
}

static BOOL NDShouldCountInterface(const char *name, short flags) {
    if (!name || !name[0]) return NO;
    if ((flags & IFF_LOOPBACK) || !(flags & IFF_UP)) return NO;
    if (strncmp(name, "en", 2) == 0) return YES;
    return NO;
}

static BOOL NDNetTotals(uint64_t *inBytes, uint64_t *outBytes) {
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return NO;

    uint64_t inTotal = 0, outTotal = 0;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        if (!NDShouldCountInterface(p->ifa_name, p->ifa_flags)) continue;

        struct if_data *data = (struct if_data *)p->ifa_data;
        if (!data) continue;
        inTotal += data->ifi_ibytes;
        outTotal += data->ifi_obytes;
    }
    freeifaddrs(ifa);

    *inBytes = inTotal;
    *outBytes = outTotal;
    return YES;
}

static void NDSetText(CATextLayer *layer, NSString *text) {
    if (!layer || !text) return;
    id cur = layer.string;
    if ([cur isKindOfClass:[NSString class]] && [(NSString *)cur isEqualToString:text])
        return;
    if ([cur isKindOfClass:[NSAttributedString class]]
        && [[(NSAttributedString *)cur string] isEqualToString:text])
        return;
    layer.string = text;
}

static void NDRefreshStats(void) {
    if (!gDiskLayer) return;

    NDPerfTick();

    uint64_t diskUsed = 0, diskTotal = 0;
    unsigned int diskPct = 0;
    if (NDDiskUsage(&diskUsed, &diskTotal, &diskPct)) {
        if (gVerticalCompact) {
            NDSetText(gDiskLayer, [NSString stringWithFormat:@"DISK\n%@",
                                  NDFormatDiskVertical(diskUsed)]);
        } else {
            NDSetText(gDiskLayer, [NSString stringWithFormat:@"DISK %@/%@ %u%%",
                                  NDFormatDiskGB(diskUsed), NDFormatDiskGB(diskTotal), diskPct]);
        }
    }

    uint64_t ramUsed = 0, ramTotal = 0;
    if (NDRamUsage(&ramUsed, &ramTotal)) {
        if (gVerticalCompact) {
            NDSetText(gRamLayer, [NSString stringWithFormat:@"RAM\n%@",
                                  NDFormatBytesShort(ramUsed)]);
        } else {
            NDSetText(gRamLayer, [NSString stringWithFormat:@"RAM  %@ / %@",
                                  NDFormatBytes(ramUsed), NDFormatBytes(ramTotal)]);
        }
    }

    unsigned int cpuMHz = 0, gpuMHz = 0;
    BOOL hasCpu = NDPerfCPUMHz(&cpuMHz);
    BOOL hasGpu = NDPerfGPUMHz(&gpuMHz);
    if (hasCpu || hasGpu) {
        if (gVerticalCompact) {
            NSString *cpu = hasCpu ? NDFormatClockVertical(cpuMHz) : @"…";
            NSString *gpu = hasGpu ? NDFormatClockVertical(gpuMHz) : @"…";
            NDSetText(gChipLayer, [NSString stringWithFormat:@"CPU\n%@\nGPU\n%@", cpu, gpu]);
        } else {
            NSString *cpu = hasCpu ? NDFormatClockMHz(cpuMHz) : @"…";
            NSString *gpu = hasGpu ? NDFormatClockMHz(gpuMHz) : @"…";
            NDSetText(gChipLayer, [NSString stringWithFormat:@"CPU %@ | GPU %@", cpu, gpu]);
        }
    } else {
        NDSetText(gChipLayer, gVerticalCompact ? @"CPU\n…\nGPU\n…" : @"CPU … | GPU …");
    }

    uint64_t netIn = 0, netOut = 0;
    if (NDNetTotals(&netIn, &netOut)) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gHasNetSample && now > gPrevNetTime) {
            double dt = now - gPrevNetTime;
            double downBps = (netIn >= gPrevNetIn) ? (double)(netIn - gPrevNetIn) / dt : 0;
            double upBps = (netOut >= gPrevNetOut) ? (double)(netOut - gPrevNetOut) / dt : 0;
            if (gVerticalCompact) {
                NDSetText(gNetUpLayer, [NSString stringWithFormat:@"↑ %@", NDFormatRateShort(upBps)]);
                NDSetText(gNetDownLayer, [NSString stringWithFormat:@"↓ %@", NDFormatRateShort(downBps)]);
            } else {
                NDSetText(gNetUpLayer, [NSString stringWithFormat:@"↑ %@", NDFormatRate(upBps)]);
                NDSetText(gNetDownLayer, [NSString stringWithFormat:@"↓ %@", NDFormatRate(downBps)]);
            }
        } else {
            NDSetText(gNetUpLayer, gVerticalCompact ? @"↑ 0" : @"↑ 0 B/s");
            NDSetText(gNetDownLayer, gVerticalCompact ? @"↓ 0" : @"↓ 0 B/s");
        }
        gPrevNetIn = netIn;
        gPrevNetOut = netOut;
        gPrevNetTime = now;
        gHasNetSample = YES;
    }
}

void NDStatsBindLayers(CATextLayer *disk, CATextLayer *ram, CATextLayer *chip,
                       CATextLayer *netUp, CATextLayer *netDown) {
    gDiskLayer = disk;
    gRamLayer = ram;
    gChipLayer = chip;
    gNetUpLayer = netUp;
    gNetDownLayer = netDown;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NDPerfInit();
    });

    NDRefreshStats();
}

void NDStatsStart(void) {
    if (gStatsStarted) return;
    gStatsStarted = YES;

    dispatch_queue_t q = dispatch_get_main_queue();
    gStatsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!gStatsTimer) return;

    dispatch_source_set_timer(gStatsTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gStatsTimer, ^{
        NDRefreshStats();
    });
    dispatch_resume(gStatsTimer);
}

void NDStatsTick(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - gLastLayoutTick < 1.2) return;
    gLastLayoutTick = now;
    NDRefreshStats();
}

void NDStatsSetVerticalCompact(BOOL compact) {
    if (gVerticalCompact == compact) return;
    gVerticalCompact = compact;
    NDRefreshStats();
}
