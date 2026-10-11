// SPDX-License-Identifier: GPL-3.0-or-later
// Native discovery and runtime selectors adapted from Ice 2's NativeMenuBarBridge
// and macos27-prototype, copyright (C) 2026 Teddy Chan. See THIRD_PARTY_NOTICES.md.
#import "NativeMenuBar.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>
static id Attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

@interface NBMenuBarEntry ()
@property(nonatomic, readwrite) NSString *bundle;
@property(nonatomic, readwrite) NSString *label;
@property(nonatomic, readwrite) CGRect frame;
@property(nonatomic, strong) id element;
@end
@implementation NBMenuBarEntry
@end

static CGRect ElementFrame(AXUIElementRef element) {
    CGPoint point = CGPointZero; CGSize size = CGSizeZero;
    id position = Attribute(element, kAXPositionAttribute), dimensions = Attribute(element, kAXSizeAttribute);
    if (position && dimensions && CFGetTypeID((__bridge CFTypeRef)position) == AXValueGetTypeID() &&
        CFGetTypeID((__bridge CFTypeRef)dimensions) == AXValueGetTypeID()) {
        AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &point);
        AXValueGetValue((__bridge AXValueRef)dimensions, kAXValueCGSizeType, &size);
    }
    return (CGRect){point, size};
}

static void CollectEntries(AXUIElementRef element, CGRect screen, CGRect region, NSUInteger depth,
                           NSMutableDictionary *entries, NSUInteger *budget) {
    if (depth > 6 || !*budget) return;
    (*budget)--;
    if ([Attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuBarItemRole]) {
        CGRect frame = ElementFrame(element);
        pid_t pid = 0; AXUIElementGetPid(element, &pid);
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        if (app.bundleIdentifier && frame.size.width > 0 && frame.size.height > 0 &&
            CGRectContainsRect(screen, frame) && CGRectContainsPoint(region, center)) {
            NSString *key = [NSString stringWithFormat:@"%@:%@", app.bundleIdentifier, NSStringFromRect(frame)];
            NBMenuBarEntry *entry = [NBMenuBarEntry new];
            entry.bundle = app.bundleIdentifier; entry.frame = frame; entry.element = (__bridge id)element;
            NSString *title = Attribute(element, kAXDescriptionAttribute) ?: Attribute(element, kAXTitleAttribute);
            entry.label = title.length ? title : (app.localizedName ?: entry.bundle);
            entries[key] = entry;
        }
        return;
    }
    id children = Attribute(element, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class])
        for (id child in children) CollectEntries((__bridge AXUIElementRef)child, screen, region, depth + 1, entries, budget);
}

NSArray<NBMenuBarEntry *> *NBMenuBarEntries(CGRect screenFrame) {
    if (!AXIsProcessTrusted()) return @[];
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return @[];
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.15);
    NSMutableDictionary *entries = [NSMutableDictionary dictionary]; NSUInteger budget = 4096;
    id windows = Attribute(root, kAXChildrenAttribute);
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if (![Attribute(win, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
        id groups = Attribute(win, kAXChildrenAttribute);
        if ([groups isKindOfClass:NSArray.class]) for (id group in groups) {
            AXUIElementRef element = (__bridge AXUIElementRef)group;
            CollectEntries(element, screenFrame, ElementFrame(element), 0, entries, &budget);
        }
    }
    CFRelease(root);
    if (!budget) return @[];
    return [entries.allValues sortedArrayUsingComparator:^NSComparisonResult(NBMenuBarEntry *a, NBMenuBarEntry *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return [a.bundle compare:b.bundle];
    }];
}

BOOL NBPressMenuBarEntry(NSString *bundle, NSUInteger index, CGRect screenFrame) {
    NSArray *entries = [NBMenuBarEntries(screenFrame) filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NBMenuBarEntry *entry, NSDictionary *bindings) { return [entry.bundle isEqual:bundle]; }]];
    if (index >= entries.count) return NO;
    NBMenuBarEntry *entry = entries[index];
    return AXUIElementPerformAction((__bridge AXUIElementRef)entry.element, kAXPressAction) == kAXErrorSuccess;
}

static BOOL HasMenu(AXUIElementRef element, NSUInteger depth, NSUInteger *budget) {
    if (depth > 5 || !*budget) return NO;
    (*budget)--;
    if ([Attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuRole]) {
        CGRect frame = ElementFrame(element);
        if (frame.size.width > 0 && frame.size.height > 0) return YES;
    }
    id children = Attribute(element, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) for (id child in children)
        if (HasMenu((__bridge AXUIElementRef)child, depth + 1, budget)) return YES;
    return NO;
}

BOOL NBMenuIsOpen(NSString *bundle) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].firstObject;
    if (!app) return NO;
    AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.1);
    NSUInteger budget = 256; BOOL result = HasMenu(root, 0, &budget); CFRelease(root);
    return result;
}

BOOL NBIsEmptyMenuBarPoint(CGPoint point) {
    if (!AXIsProcessTrusted()) return NO;
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return NO;
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    id windows = Attribute(root, kAXChildrenAttribute);
    BOOL inBar = NO;
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if ([Attribute(win, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] &&
            CGRectContainsPoint(ElementFrame(win), point)) { inBar = YES; break; }
    }
    CFRelease(root);
    if (!inBar) return NO;
    AXUIElementRef system = AXUIElementCreateSystemWide(), hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(system, point.x, point.y, &hit);
    CFRelease(system);
    if (error != kAXErrorSuccess || !hit) return NO;
    NSString *role = Attribute(hit, kAXRoleAttribute);
    pid_t pid = 0; AXUIElementGetPid(hit, &pid); CFRelease(hit);
    return [role isEqual:(__bridge NSString *)kAXMenuBarRole] ||
        (pid == agent.processIdentifier && ([role isEqual:(__bridge NSString *)kAXWindowRole] || [role isEqual:(__bridge NSString *)kAXGroupRole]));
}

CGRect NBEmptyStatusSlot(CGRect screenFrame, CGRect expectedFrame) {
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return CGRectNull;
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    id windows = Attribute(root, kAXChildrenAttribute);
    CGRect closest = CGRectNull; CGFloat distance = CGFLOAT_MAX;
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if (![Attribute(win, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
        id groups = Attribute(win, kAXChildrenAttribute);
        if ([groups isKindOfClass:NSArray.class]) for (id group in groups) {
            AXUIElementRef element = (__bridge AXUIElementRef)group;
            CGRect rect = ElementFrame(element);
            if (rect.size.width < 20 || rect.size.width > 50 || !CGRectContainsRect(screenFrame, rect)) continue;
            NSMutableDictionary *items = [NSMutableDictionary dictionary]; NSUInteger budget = 256;
            CollectEntries(element, screenFrame, rect, 0, items, &budget);
            if (!budget || items.count) continue;
            CGFloat delta = fabs(CGRectGetMidX(rect) - CGRectGetMidX(expectedFrame));
            if (delta < distance) { closest = rect; distance = delta; }
        }
    }
    CFRelease(root);
    return closest;
}

static void CollectOwners(AXUIElementRef element, pid_t agentPID, NSUInteger depth,
                          NSMutableSet<NSString *> *owners, NSUInteger *budget) {
    if (depth > 4 || *budget == 0) return;
    (*budget)--;
    pid_t pid = 0;
    AXUIElementGetPid(element, &pid);
    NSString *bundle = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier;
    if (pid != agentPID && bundle) {
        [owners addObject:bundle];
        return;
    }
    id children = Attribute(element, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) {
        for (id child in children) CollectOwners((__bridge AXUIElementRef)child, agentPID, depth + 1, owners, budget);
    }
}

NSDictionary *NBMenuBarSnapshot(void) {
    if (!AXIsProcessTrusted()) return @{@"error": @"Enable NookBar's Accessibility access in System Settings."};
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return @{@"error": @"The system menu bar service is unavailable."};
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.15);
    id children = Attribute(root, kAXChildrenAttribute);
    if (![children isKindOfClass:NSArray.class]) {
        CFRelease(root);
        return @{@"error": @"Could not read the menu bar. Check Accessibility access and try again."};
    }
    NSMutableDictionary<NSString *, NSNumber *> *occurrences = [NSMutableDictionary dictionary];
    NSUInteger groupCount = 0, budget = 1024, windowCount = 0;
    BOOL failed = NO;
    for (id window in children) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if (![Attribute(win, kAXRoleAttribute) isEqual:@"AXWindow"]) continue;
        windowCount++;
        id groups = Attribute(win, kAXChildrenAttribute);
        if (![groups isKindOfClass:NSArray.class]) { failed = YES; break; }
        for (id group in groups) {
            groupCount++;
            NSMutableSet *owners = [NSMutableSet set];
            CollectOwners((__bridge AXUIElementRef)group, agent.processIdentifier, 0, owners, &budget);
            for (NSString *bundle in owners) occurrences[bundle] = @([occurrences[bundle] unsignedIntegerValue] + 1);
        }
    }
    CFRelease(root);
    if (failed || !windowCount || !budget) return @{@"error": @"Menu bar discovery was incomplete. Show all items and try again."};
    return @{@"occurrences": occurrences, @"groupCount": @(groupCount)};
}

static BOOL Available(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY);
    });
    return framework &&
        [NSClassFromString(@"MBAssessmentModeConfiguration") instancesRespondToSelector:NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:")] &&
        [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:NSSelectorFromString(@"activateWithConfiguration:completionHandler:")] &&
        [NSClassFromString(@"MBAssessmentModeAssertion") instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
}

@interface NBVisibilityController ()
@property(nonatomic, strong) id assertion;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, readwrite) BOOL active;
@property(nonatomic, copy) void (^pendingCompletion)(BOOL, NSString *);
@end

@implementation NBVisibilityController
- (void)restore {
    NSAssert(NSThread.isMainThread, @"Visibility changes require the main thread");
    self.generation++;
    void (^pending)(BOOL, NSString *) = self.pendingCompletion;
    self.pendingCompletion = nil;
    if (self.assertion) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(self.assertion, NSSelectorFromString(@"invalidate"));
        } @catch (NSException *exception) {
            NSLog(@"NookBar restoration failed: %@", exception.reason);
        }
        self.assertion = nil;
    }
    self.active = NO;
    if (pending) pending(NO, @"Hiding was cancelled. Apps are shown.");
}

- (void)hideBundles:(NSArray<NSString *> *)bundles completion:(void (^)(BOOL, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Visibility changes require the main thread");
    [self restore];
    if (!bundles.count) { completion(NO, @"Choose at least one app to hide."); return; }
    if (!AXIsProcessTrusted() || !Available()) {
        completion(NO, @"Menu bar control is unavailable. Check Accessibility access."); return;
    }
    NSSet *hidden = [NSSet setWithArray:bundles];
    NSMutableSet *allowed = [NSMutableSet set];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.bundleIdentifier && ![hidden containsObject:app.bundleIdentifier]) [allowed addObject:app.bundleIdentifier];
    }
    NSString *own = NSBundle.mainBundle.bundleIdentifier;
    if (own && ![hidden containsObject:own]) [allowed addObject:own];
    if (![hidden containsObject:@"com.codenest.nookbar"]) [allowed addObject:@"com.codenest.nookbar"];
    NSUInteger generation = self.generation;
    __block BOOL completed = NO;
    self.pendingCompletion = completion;
    @try {
        id configuration = ((id (*)(id, SEL, id, id))objc_msgSend)(
            [NSClassFromString(@"MBAssessmentModeConfiguration") alloc],
            NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:"),
            @[@0, @1, @2, @3, @4, @5, @6, @7, @8], allowed.allObjects);
        self.assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!configuration || !self.assertion) {
            void (^callback)(BOOL, NSString *) = self.pendingCompletion;
            self.pendingCompletion = nil;
            [self restore]; callback(NO, @"Could not start menu bar control."); return;
        }
        __weak NBVisibilityController *weakSelf = self;
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(self.assertion,
            NSSelectorFromString(@"activateWithConfiguration:completionHandler:"), configuration, ^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NBVisibilityController *owner = weakSelf;
                    if (!owner || completed || owner.generation != generation) return;
                    completed = YES;
                    void (^callback)(BOOL, NSString *) = owner.pendingCompletion;
                    owner.pendingCompletion = nil;
                    if (error) [owner restore];
                    else owner.active = YES;
                    if (callback) callback(!error, error.localizedDescription);
                });
            });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NBVisibilityController *owner = weakSelf;
            if (!owner || completed || owner.generation != generation) return;
            completed = YES;
            void (^callback)(BOOL, NSString *) = owner.pendingCompletion;
            owner.pendingCompletion = nil;
            [owner restore];
            if (callback) callback(NO, @"Menu bar control timed out. Items have been restored.");
        });
    } @catch (NSException *exception) {
        completed = YES;
        void (^callback)(BOOL, NSString *) = self.pendingCompletion;
        self.pendingCompletion = nil;
        [self restore];
        if (callback) callback(NO, exception.reason ?: @"Menu bar control failed.");
    }
}
@end
