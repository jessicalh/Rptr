//
//  RptrApplication.m
//  Rptr
//
//  Custom UIApplication subclass to prevent menu/storyboard crashes
//

#import "RptrApplication.h"

@implementation RptrApplication

- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
    // Override at the UIApplication level to prevent storyboard loading
    // Do NOT call super - this stops the menu building chain completely
    // This prevents crashes when keyboard appears in text fields
    return;
}

// Disable keyboard shortcuts completely
- (NSArray<UIKeyCommand *> *)keyCommands {
    return @[];
}

// Prevent key command processing
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    // Allow standard text editing actions
    if (action == @selector(cut:) ||
        action == @selector(copy:) ||
        action == @selector(paste:) ||
        action == @selector(select:) ||
        action == @selector(selectAll:) ||
        action == @selector(delete:)) {
        return [super canPerformAction:action withSender:sender];
    }
    
    // Disable all other actions to prevent menu building
    return NO;
}

@end