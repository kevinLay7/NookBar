// SPDX-License-Identifier: GPL-3.0-or-later
// Native discovery and runtime selectors adapted from Ice 2's NativeMenuBarBridge
// and macos27-prototype, copyright (C) 2026 Teddy Chan. See THIRD_PARTY_NOTICES.md.
#import "NativeMenuBar.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <unistd.h>
static const int64_t OverflowEventMarker = 0x4E424F46;

BOOL NBIsOwnMenuBarOverflowEvent(CGEventRef event) {
    return event && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == OverflowEventMarker &&
        CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID) == getpid();
}
static id Attribute(AXUIElementRef element, CFStringRef key) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, key, &value) != kAXErrorSuccess) return nil;
    return CFBridgingRelease(value);
}

static NSString *TextAttribute(AXUIElementRef element, CFStringRef key) {
    id value = Attribute(element, key);
    return [value isKindOfClass:NSString.class] ? value : @"";
}

@interface NBMenuBarEntry ()
@property(nonatomic, readwrite) NSString *bundle;
@property(nonatomic, readwrite) NSString *label;
@property(nonatomic, readwrite) CGRect frame;
@property(nonatomic, strong) id element;
@property(nonatomic, strong) NSRunningApplication *owner;
@property(nonatomic, strong) NSDate *launchDate;
@property(nonatomic, copy) NSString *descriptorKind;
@property(nonatomic, copy) NSString *descriptor;
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
                           NSMutableArray *entries, NSUInteger *budget) {
    if (depth > 6 || !*budget) return;
    (*budget)--;
    if ([Attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuBarItemRole]) {
        CGRect frame = ElementFrame(element);
        pid_t pid = 0; AXUIElementGetPid(element, &pid);
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        if (app.bundleIdentifier && frame.size.width > 0 && frame.size.height > 0 &&
            CGRectContainsRect(screen, frame)) {
            NBMenuBarEntry *entry = [NBMenuBarEntry new];
            entry.bundle = app.bundleIdentifier; entry.frame = frame; entry.element = (__bridge id)element;
            entry.owner = app; entry.launchDate = app.launchDate;
            NSString *description = TextAttribute(element, kAXDescriptionAttribute);
            NSString *title = TextAttribute(element, kAXTitleAttribute);
            NSString *identifier = TextAttribute(element, kAXIdentifierAttribute);
            entry.descriptorKind = identifier.length ? @"identifier" : (description.length ? @"description" : (title.length ? @"title" : @"none"));
            entry.descriptor = identifier.length ? identifier : (description.length ? description : title);
            NSString *label = description.length ? description : title;
            if (!label.length) label = TextAttribute(element, kAXHelpAttribute);
            entry.label = label.length ? label : (app.localizedName ?: entry.bundle);
            // Several collapsed icons can share one positive frame. Deduplicate
            // replicated AX trees by identity instead of dropping those icons.
            for (NBMenuBarEntry *existing in entries) {
                // Deduplication within this query does not require launch-date
                // evidence; some system agents do not supply it. Resolution
                // across queries still requires that evidence in NBSameMenuBarEntry.
                if (existing.owner.processIdentifier == entry.owner.processIdentifier &&
                    CFEqual((__bridge CFTypeRef)existing.element, (__bridge CFTypeRef)entry.element) &&
                    CGRectEqualToRect(existing.frame, frame)) return;
            }
            // Expansion updates the owning app's status-item frames before all
            // MenuBarAgent group copies update. Accept those exposed extras by
            // live hit identity, without admitting the app's ordinary menus.
            if (!CGRectContainsPoint(region, center) &&
                (![Attribute(element, kAXSubroleAttribute) isEqual:@"AXMenuExtra"] || !NBMenuBarEntryIsExposed(entry))) return;
            [entries addObject:entry];
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
    NSMutableArray *entries = [NSMutableArray array]; NSUInteger budget = 4096;
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
    // SwiftUI system extras have separate AX identities in inactive Space copies.
    // An exposed copy identifies the actual pixels at this frame; retain unknown
    // collapsed identities when no exposed copy proves which one is current.
    NSArray *exposedSystem = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NBMenuBarEntry *entry, NSDictionary *bindings) {
        return [entry.bundle isEqual:@"com.apple.MenuBarAgent"] && NBMenuBarEntryIsExposed(entry);
    }]];
    NSArray *normalized = [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NBMenuBarEntry *entry, NSDictionary *bindings) {
        if (![entry.bundle isEqual:@"com.apple.MenuBarAgent"]) return YES;
        for (NBMenuBarEntry *exposed in exposedSystem) {
            if (CGRectEqualToRect(entry.frame, exposed.frame) && [entry.label isEqual:exposed.label] &&
                !CFEqual((__bridge CFTypeRef)entry.element, (__bridge CFTypeRef)exposed.element)) return NO;
        }
        return YES;
    }]];
    return [normalized sortedArrayUsingComparator:^NSComparisonResult(NBMenuBarEntry *a, NBMenuBarEntry *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return [a.bundle compare:b.bundle];
    }];
}

BOOL NBMenuBarEntryMatchesPoint(NBMenuBarEntry *entry, CGPoint point) {
    if (!entry.element || !CGRectContainsPoint(entry.frame, point)) return NO;
    AXUIElementRef root = AXUIElementCreateSystemWide(), hit = NULL;
    AXError error = AXUIElementCopyElementAtPosition(root, point.x, point.y, &hit);
    CFRelease(root);
    if (error != kAXErrorSuccess || !hit) return NO;
    BOOL matches = NO;
    for (NSUInteger depth = 0; hit && depth < 5; depth++) {
        if (CFEqual(hit, (__bridge CFTypeRef)entry.element)) { matches = YES; break; }
        id parent = Attribute(hit, kAXParentAttribute);
        CFRelease(hit);
        hit = parent ? (AXUIElementRef)CFRetain((__bridge CFTypeRef)parent) : NULL;
    }
    if (hit) CFRelease(hit);
    return matches;
}

BOOL NBSameMenuBarEntry(NBMenuBarEntry *first, NBMenuBarEntry *second) {
    return first.element && second.element && first.owner && second.owner &&
        !first.owner.isTerminated && !second.owner.isTerminated &&
        first.owner.processIdentifier == second.owner.processIdentifier &&
        first.launchDate && [first.launchDate isEqualToDate:second.launchDate] &&
        [first.bundle isEqual:second.bundle] &&
        CFEqual((__bridge CFTypeRef)first.element, (__bridge CFTypeRef)second.element);
}

BOOL NBMenuBarEntryIsExposed(NBMenuBarEntry *entry) {
    if (!entry.element || !entry.owner || entry.owner.isTerminated) return NO;
    CGRect frame = ElementFrame((__bridge AXUIElementRef)entry.element);
    if (!CGRectEqualToRect(frame, entry.frame) || frame.size.width <= 0 || frame.size.height <= 0) return NO;
    // Collapsed overflow items retain positive AX frames over the native overflow
    // button. Their geometry alone does not identify the pixels being sampled.
    return NBMenuBarEntryMatchesPoint(entry, CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)));
}

BOOL NBSameMenuBarEntryDescriptor(NBMenuBarEntry *first, NBMenuBarEntry *second) {
    // AXHelp is a tooltip, not an identity label. For example, fan RPM changes
    // update help while the AX/process identity and primary descriptor persist.
    return NBSameMenuBarEntry(first, second) && [first.descriptorKind isEqual:second.descriptorKind] &&
        [first.descriptor isEqual:second.descriptor];
}

static AXUIElementRef CopyOverflowControl(CGRect screenFrame, NSInteger *state) {
    *state = -1;
    if (!AXIsProcessTrusted()) return NULL;
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return NULL;
    NSBundle *bundle = [NSBundle bundleWithURL:agent.bundleURL];
    NSString *show = [bundle localizedStringForKey:@"menuBar.showOverflowItemsAccessibilityLabel" value:nil table:@"MenuBarCore"];
    NSString *hide = [bundle localizedStringForKey:@"menuBar.hideOverflowItemsAccessibilityLabel" value:nil table:@"MenuBarCore"];
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.15);
    AXUIElementRef system = AXUIElementCreateSystemWide(), found = NULL;
    id windows = Attribute(root, kAXChildrenAttribute);
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if (![Attribute(win, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
        id children = Attribute(win, kAXChildrenAttribute);
        if (![children isKindOfClass:NSArray.class]) continue;
        for (id child in children) {
            AXUIElementRef candidate = (__bridge AXUIElementRef)child;
            NSString *label = Attribute(candidate, kAXDescriptionAttribute);
            if (![Attribute(candidate, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXButtonRole] ||
                (![label isEqual:show] && ![label isEqual:hide])) continue;
            CGRect frame = ElementFrame(candidate);
            if (CGRectIsEmpty(frame) || !CGRectContainsRect(screenFrame, frame)) continue;
            AXUIElementRef hit = NULL;
            if (AXUIElementCopyElementAtPosition(system, CGRectGetMidX(frame), CGRectGetMidY(frame), &hit) != kAXErrorSuccess || !hit) continue;
            pid_t pid = 0; AXUIElementGetPid(hit, &pid);
            NSString *actual = Attribute(hit, kAXDescriptionAttribute);
            if (pid == agent.processIdentifier && [Attribute(hit, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXButtonRole] &&
                ([actual isEqual:show] || [actual isEqual:hide])) {
                *state = [actual isEqual:hide] ? 1 : 0;
                found = hit; break;
            }
            CFRelease(hit);
        }
        if (found) break;
    }
    CFRelease(system); CFRelease(root);
    return found;
}

NSInteger NBMenuBarOverflowState(CGRect screenFrame) {
    NSInteger state; AXUIElementRef control = CopyOverflowControl(screenFrame, &state);
    if (control) CFRelease(control);
    return state;
}

BOOL NBSetMenuBarOverflowExpanded(CGRect screenFrame, BOOL expanded) {
    NSInteger state; AXUIElementRef control = CopyOverflowControl(screenFrame, &state);
    if (!control) return NO;
    BOOL success = state == (expanded ? 1 : 0);
    if (!success && CGPreflightPostEventAccess() &&
        !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) &&
        !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) &&
        !CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonCenter)) {
        // The exposed native overflow button advertises no AXPress action on
        // macOS 27. Click only this hit-tested control, never an inactive AX copy.
        CGRect frame = ElementFrame(control);
        CGPoint point = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        CGEventRef cursor = CGEventCreate(NULL);
        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
        CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
        if (cursor && down && up) {
            CGEventSetIntegerValueField(down, kCGEventSourceUserData, OverflowEventMarker);
            CGEventSetIntegerValueField(up, kCGEventSourceUserData, OverflowEventMarker);
            CGEventSetFlags(down, 0); CGEventSetFlags(up, 0);
            CGEventPost(kCGHIDEventTap, down); CGEventPost(kCGHIDEventTap, up);
            CGEventRef restore = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGEventGetLocation(cursor), kCGMouseButtonLeft);
            if (restore) { CGEventSetFlags(restore, CGEventGetFlags(cursor)); CGEventPost(kCGHIDEventTap, restore); CFRelease(restore); }
            success = YES; // Delivery only; the caller must verify the new state.
        }
        if (cursor) CFRelease(cursor);
        if (down) CFRelease(down);
        if (up) CFRelease(up);
    }
    CFRelease(control);
    return success;
}

NBMenuBarEntry *NBResolveMenuBarEntry(NBMenuBarEntry *entry, CGRect screenFrame) {
    NSArray *matches = [NBMenuBarEntries(screenFrame) filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NBMenuBarEntry *candidate, NSDictionary *bindings) {
            return NBSameMenuBarEntryDescriptor(candidate, entry);
        }]];
    // Reject missing, ambiguous, renamed, or restarted items without guessing an
    // ordinal. macOS may still reuse an AX identity for same-label replacements.
    return matches.count == 1 ? matches.firstObject : nil;
}

BOOL NBPressMenuBarEntry(NBMenuBarEntry *entry, CGRect screenFrame) {
    NBMenuBarEntry *current = NBResolveMenuBarEntry(entry, screenFrame);
    if (!current || !NBMenuBarEntryIsExposed(current)) return NO;
    return AXUIElementPerformAction((__bridge AXUIElementRef)current.element, kAXPressAction) == kAXErrorSuccess;
}

BOOL NBMenuIsOpen(NSString *bundle) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].firstObject;
    if (!app) return NO;
    // Closed NSMenus can retain nonzero AX frames. Use WindowServer's actual
    // on-screen popup windows, rather than treating those cached frames as open.
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    if (!windows) return YES; // Preserve the item while visibility is unknown.
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != app.processIdentifier) continue;
        NSInteger layer = [window[(__bridge NSString *)kCGWindowLayer] integerValue];
        if (layer == NSPopUpMenuWindowLevel || layer == NSModalPanelWindowLevel) return YES;
    }
    return NO;
}

static BOOL CancelMenu(AXUIElementRef element, NSArray<NSValue *> *frames, NSUInteger depth, NSUInteger *budget) {
    if (depth > 5 || !*budget) return NO;
    (*budget)--;
    if ([Attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuRole]) {
        CGRect rect = ElementFrame(element);
        for (NSValue *frame in frames) {
            if (CGRectIntersectsRect(rect, frame.rectValue) && AXUIElementPerformAction(element, kAXCancelAction) == kAXErrorSuccess) return YES;
        }
    }
    id children = Attribute(element, kAXChildrenAttribute);
    if ([children isKindOfClass:NSArray.class]) for (id child in children)
        if (CancelMenu((__bridge AXUIElementRef)child, frames, depth + 1, budget)) return YES;
    return NO;
}

BOOL NBCancelMenu(NSString *bundle) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle].firstObject;
    if (!app) return YES;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    if (!windows) return NO;
    NSMutableArray *frames = [NSMutableArray array];
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] != app.processIdentifier ||
            [window[(__bridge NSString *)kCGWindowLayer] integerValue] != NSPopUpMenuWindowLevel) continue;
        CGRect frame;
        if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &frame))
            [frames addObject:[NSValue valueWithRect:frame]];
    }
    if (!frames.count) return !NBMenuIsOpen(bundle);
    AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.1);
    NSUInteger budget = 512;
    BOOL cancelled = CancelMenu(root, frames, 0, &budget);
    CFRelease(root);
    return cancelled;
}

CGRect NBMenuBarFrameAtPoint(CGPoint point) {
    if (!AXIsProcessTrusted()) return CGRectNull;
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return CGRectNull;
    AXUIElementRef root = AXUIElementCreateApplication(agent.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.1);
    id windows = Attribute(root, kAXChildrenAttribute);
    CGRect result = CGRectNull;
    if ([windows isKindOfClass:NSArray.class]) for (id window in windows) {
        AXUIElementRef win = (__bridge AXUIElementRef)window;
        if ([Attribute(win, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole] &&
            CGRectContainsPoint(ElementFrame(win), point)) { result = ElementFrame(win); break; }
    }
    CFRelease(root);
    return result;
}

CGRect NBApplicationMenuFrame(CGRect screenFrame) {
    if (!AXIsProcessTrusted()) return CGRectNull;
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.menuBarOwningApplication;
    if (!app) return CGRectNull;
    AXUIElementRef root = AXUIElementCreateApplication(app.processIdentifier);
    AXUIElementSetMessagingTimeout(root, 0.15);
    id menu = Attribute(root, kAXMenuBarAttribute);
    CGRect result = CGRectNull;
    if (menu && CFGetTypeID((__bridge CFTypeRef)menu) == AXUIElementGetTypeID()) {
        id children = Attribute((__bridge AXUIElementRef)menu, kAXChildrenAttribute);
        if ([children isKindOfClass:NSArray.class]) for (id child in children) {
            AXUIElementRef element = (__bridge AXUIElementRef)child;
            CGRect rect = ElementFrame(element);
            if ([Attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXMenuBarItemRole] &&
                rect.size.width > 0 && rect.size.height > 0 && CGRectContainsRect(screenFrame, rect) &&
                fabs(rect.origin.y - screenFrame.origin.y) < 2) result = CGRectUnion(result, rect);
        }
    }
    CFRelease(root);
    return result;
}

BOOL NBIsEmptyMenuBarPoint(CGPoint point) {
    if (CGRectIsNull(NBMenuBarFrameAtPoint(point))) return NO;
    NSRunningApplication *agent = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.MenuBarAgent"].firstObject;
    if (!agent) return NO;
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
            NSMutableArray *items = [NSMutableArray array]; NSUInteger budget = 256;
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
