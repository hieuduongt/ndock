#import <stdbool.h>

bool NDPerfInit(void);
void NDPerfTick(void);
bool NDPerfCPUMHz(unsigned int *mhzOut);
bool NDPerfGPUMHz(unsigned int *mhzOut);
