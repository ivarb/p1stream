@interface NSArray (P1ArrayWithMap)

- (NSMutableArray *)mapObjectsWithBlock:(id (^)(id obj, NSUInteger idx))block;

@end


@interface NSError (P1ErrorWithGError)

+ (NSError *)errorWithGError:(GError *)error;
- (NSError *)initWithGError:(GError *)error;

@end


BOOL checkAndLogGLError(NSString *action);
