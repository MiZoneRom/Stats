#import "SensorBridge.h"
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <dlfcn.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

NSDictionary<NSString *, NSNumber *> *ReadAppleHIDSensors(int32_t page, int32_t usage, int32_t eventType) {
    NSDictionary *matching = @{ @"PrimaryUsagePage": @(page), @"PrimaryUsage": @(usage) };
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) return @{};

    IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) {
        CFRelease(client);
        return @{};
    }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    for (CFIndex index = 0; index < CFArrayGetCount(services); index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        CFTypeRef rawName = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0);
        if (rawName != NULL && event != NULL && CFGetTypeID(rawName) == CFStringGetTypeID()) {
            NSString *name = (__bridge NSString *)rawName;
            double value = IOHIDEventGetFloatValue(event, eventType << 16);
            if (isfinite(value)) result[name] = @(value);
        }
        if (event != NULL) CFRelease(event);
        if (rawName != NULL) CFRelease(rawName);
    }

    CFRelease(services);
    CFRelease(client);
    return result;
}

static void *IOReportSymbol(const char *name) {
    static void *framework = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        framework = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    });
    return framework == NULL ? NULL : dlsym(framework, name);
}

CFDictionaryRef StatsIOReportCopyChannels(CFStringRef group, CFStringRef subgroup) {
    typedef CFDictionaryRef (*Function)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    Function function = (Function)IOReportSymbol("IOReportCopyChannelsInGroup");
    return function == NULL ? NULL : function(group, subgroup, 0, 0, 0);
}

StatsIOReportSubscriptionRef StatsIOReportCreateSubscription(CFMutableDictionaryRef channels, CFMutableDictionaryRef *subscribedChannels) {
    typedef StatsIOReportSubscriptionRef (*Function)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    Function function = (Function)IOReportSymbol("IOReportCreateSubscription");
    return function == NULL ? NULL : function(NULL, channels, subscribedChannels, 0, NULL);
}

CFDictionaryRef StatsIOReportCreateSamples(StatsIOReportSubscriptionRef subscription, CFMutableDictionaryRef channels) {
    typedef CFDictionaryRef (*Function)(StatsIOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
    Function function = (Function)IOReportSymbol("IOReportCreateSamples");
    return function == NULL ? NULL : function(subscription, channels, NULL);
}

CFStringRef StatsIOReportChannelGetGroup(CFDictionaryRef channel) {
    typedef CFStringRef (*Function)(CFDictionaryRef);
    Function function = (Function)IOReportSymbol("IOReportChannelGetGroup");
    return function == NULL ? NULL : function(channel);
}

CFStringRef StatsIOReportChannelGetName(CFDictionaryRef channel) {
    typedef CFStringRef (*Function)(CFDictionaryRef);
    Function function = (Function)IOReportSymbol("IOReportChannelGetChannelName");
    return function == NULL ? NULL : function(channel);
}

CFStringRef StatsIOReportChannelGetUnit(CFDictionaryRef channel) {
    typedef CFStringRef (*Function)(CFDictionaryRef);
    Function function = (Function)IOReportSymbol("IOReportChannelGetUnitLabel");
    return function == NULL ? NULL : function(channel);
}

int64_t StatsIOReportSimpleValue(CFDictionaryRef channel) {
    typedef int64_t (*Function)(CFDictionaryRef, int32_t);
    Function function = (Function)IOReportSymbol("IOReportSimpleGetIntegerValue");
    return function == NULL ? 0 : function(channel, 0);
}
