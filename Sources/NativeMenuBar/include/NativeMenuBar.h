#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Returns an error instead of confusing a failed AX query with an empty menu bar.
NSDictionary *NBMenuBarSnapshot(void);

@interface NBMenuBarEntry : NSObject
@property(nonatomic, readonly) NSString *bundle;
@property(nonatomic, readonly) NSString *label;
@property(nonatomic, readonly) CGRect frame;
@end
NSArray<NBMenuBarEntry *> *NBMenuBarEntries(CGRect screenFrame);
BOOL NBMenuBarEntryMatchesPoint(NBMenuBarEntry *entry, CGPoint point);
BOOL NBMenuBarEntryIsExposed(NBMenuBarEntry *entry);
// -1 means no exposed overflow control on this display, 0 collapsed, 1 expanded.
NSInteger NBMenuBarOverflowState(CGRect screenFrame);
BOOL NBSetMenuBarOverflowExpanded(CGRect screenFrame, BOOL expanded);
BOOL NBIsOwnMenuBarEvent(CGEventRef _Nullable event);
BOOL NBSameMenuBarEntry(NBMenuBarEntry *first, NBMenuBarEntry *second);
BOOL NBSameMenuBarEntryDescriptor(NBMenuBarEntry *first, NBMenuBarEntry *second);
NBMenuBarEntry * _Nullable NBResolveMenuBarEntry(NBMenuBarEntry *entry, CGRect screenFrame);
// Returns native click delivery; interface/action confirmation is separate.
BOOL NBPressMenuBarEntry(NBMenuBarEntry *entry, CGRect screenFrame);
NSArray<NSNumber *> * _Nullable NBMenuBarInterfaceWindowIDs(NBMenuBarEntry *entry);
BOOL NBMenuBarInterfaceIsOpen(NBMenuBarEntry *entry, NSNumber *windowID);
BOOL NBMenuIsOpen(NSString *bundle);
BOOL NBCancelMenu(NSString *bundle);
BOOL NBIsEmptyMenuBarPoint(CGPoint point);
CGRect NBMenuBarFrameAtPoint(CGPoint point);
CGRect NBApplicationMenuFrame(CGRect screenFrame);
CGRect NBEmptyStatusSlot(CGRect screenFrame, CGRect expectedFrame);

@interface NBVisibilityController : NSObject
@property(nonatomic, readonly) BOOL active;
- (void)hideBundles:(NSArray<NSString *> *)bundles
         completion:(void (^)(BOOL success, NSString * _Nullable message))completion;
- (void)restore;
@end
NS_ASSUME_NONNULL_END
