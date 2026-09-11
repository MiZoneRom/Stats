#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>

typedef void *StatsIOReportSubscriptionRef;

NSDictionary<NSString *, NSNumber *> *ReadAppleHIDSensors(int32_t page, int32_t usage, int32_t eventType);

CFDictionaryRef StatsIOReportCopyChannels(CFStringRef group, CFStringRef subgroup) CF_RETURNS_RETAINED;
StatsIOReportSubscriptionRef StatsIOReportCreateSubscription(CFMutableDictionaryRef channels, CFMutableDictionaryRef *subscribedChannels);
CFDictionaryRef StatsIOReportCreateSamples(StatsIOReportSubscriptionRef subscription, CFMutableDictionaryRef channels) CF_RETURNS_RETAINED;
CFStringRef StatsIOReportChannelGetGroup(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef StatsIOReportChannelGetName(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
CFStringRef StatsIOReportChannelGetUnit(CFDictionaryRef channel) CF_RETURNS_NOT_RETAINED;
int64_t StatsIOReportSimpleValue(CFDictionaryRef channel);
