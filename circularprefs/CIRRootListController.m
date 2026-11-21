#import <Preferences/PSListController.h>

@interface CIRRootListController : PSListController
@end

@implementation CIRRootListController
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}
@end
