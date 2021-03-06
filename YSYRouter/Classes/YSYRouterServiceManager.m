//
//  YSYRouterServiceManager.m
//  FBSnapshotTestCase
//
//  Created by muxue on 2018/12/3.
//

#import "YSYRouterServiceManager.h"
#import <objc/message.h>

NSString *const YSYRouterParameterModuleName = @"YSYRouterParameterModuleName";
NSString *const YSYRouterParameterAction = @"YSYRouterParameterAction";
NSString *const YSYRouterParameterUserInfo = @"YSYRouterParameterUserInfo";

/** 路由表 */
static NSMutableDictionary<NSString *, Class> *routerTable = nil;
static dispatch_semaphore_t semaphore = NULL;
/** 缓存表 */
static NSMutableDictionary<NSString *, id<YSYComponentInterfaceProtocol>> *cacheTable = nil;

CG_INLINE void YSYRouterCreateSemaphore() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        semaphore = dispatch_semaphore_create(1);
        routerTable = [NSMutableDictionary dictionaryWithCapacity:5];
        cacheTable = [NSMutableDictionary dictionaryWithCapacity:5];
    });
}

// 当前顶层显示的视图控制器
static UIViewController *YSYTopViewController = nil;
static dispatch_semaphore_t YSYTopViewControllerSemaphore = NULL;

CG_INLINE void YSYCreateTopViewControllerSemaphore() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YSYTopViewControllerSemaphore = dispatch_semaphore_create(1);
    });
}

CG_INLINE void YSYSetTopViewController(UIViewController *viewController) {
    YSYCreateTopViewControllerSemaphore();
    if (!viewController.navigationController ||
        [viewController isEqual:UINavigationController.class] ||
        [viewController isEqual:UITabBarController.class]) return;
    
    dispatch_semaphore_wait(YSYTopViewControllerSemaphore, DISPATCH_TIME_FOREVER);
    YSYTopViewController = viewController;
    dispatch_semaphore_signal(YSYTopViewControllerSemaphore);
}

UIViewController *YSYGetTopViewController() {
    YSYCreateTopViewControllerSemaphore();
    dispatch_semaphore_wait(YSYTopViewControllerSemaphore, DISPATCH_TIME_FOREVER);
    UIViewController *viewController = YSYTopViewController;
    // 跳转过程中 导航视图被释放的情况,顶部控制器被弹出的情况
    if (!viewController.navigationController) {
        // 取得当前应用程序根视图控制器
        UIViewController *rootViewController = [UIApplication sharedApplication].keyWindow.rootViewController;
        // r如果根视图控制器是 标签控制器
        if ([rootViewController isKindOfClass:UITabBarController.class]) {
            // 取得当前标签
            UIViewController *selectViewController = [(UITabBarController *)rootViewController selectedViewController];
            // 假如当前标签为一个 导航控制器，则取出导航标签中的最后一个控制器
            if ([selectViewController isKindOfClass:UINavigationController.class]) {
                viewController = [(UINavigationController *)selectViewController viewControllers].lastObject;
                // 当前标签不是导航标签
            } else if (selectViewController) {
                 viewController = selectViewController;
                // 没有子标签
            } else {
                 viewController = nil;
            }
        } else if (![rootViewController isKindOfClass:UINavigationController.class]) {
             viewController = [(UINavigationController *)rootViewController viewControllers].lastObject;
        } else {
            viewController = rootViewController;
        }
        YSYTopViewController = viewController;
    }
    dispatch_semaphore_signal(YSYTopViewControllerSemaphore);
    return viewController;
}

@implementation YSYRouterServiceManager

+ (void)share {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YSYRouterCreateSemaphore();
        //监听主线程进入运行循环和退出运行循环
        CFRunLoopObserverRef observer = CFRunLoopObserverCreateWithHandler(CFAllocatorGetDefault(), kCFRunLoopAllActivities, YES, 0, ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            switch (activity) {
                case kCFRunLoopEntry:
                    // 收到内存警告，清空缓存
                    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cleanCacheTable) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
                    break;
                case kCFRunLoopExit:
                    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
                    break;
                default:
                    break;
            }
        });
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopDefaultMode);
        // 应用程序退到后台，需清空缓存
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cleanCacheTable) name:UIApplicationDidEnterBackgroundNotification object:nil];
    });
}

/** 清空缓存表 */
+ (void)cleanCacheTable {
    if (cacheTable.count <= 0) return;
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    NSDictionary *cache = cacheTable;
    cacheTable = [NSMutableDictionary dictionary];
    dispatch_semaphore_signal(semaphore);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        [cache class];
    });
}

+ (BOOL)registerModuleWithUrl:(NSString *)url moduleClass:(Class)objcClass {
    @autoreleasepool {
        [self share];
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        if (routerTable[url] == nil) {
            [routerTable setValue:objcClass forKey:url];
        }
        dispatch_semaphore_signal(semaphore);
        return YES;
    }
}

+ (void)writeOffModuleWithUrl:(NSString *)url {
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    [routerTable removeObjectForKey:url];
    dispatch_semaphore_signal(semaphore);
}
    
+ (id<YSYComponentInterfaceProtocol>)callUrl:(NSString *)url {
    return [self callUrl:url callBack:nil];
}

+ (id<YSYComponentInterfaceProtocol>)openUrl:(NSURL *)url {
    return [self openUrl:url parameter:nil callBack:nil];
}

+ (id<YSYComponentInterfaceProtocol>)openUrlString:(NSString *)urlString {
    return [self openUrl:[NSURL URLWithString:urlString]];
}

+ (id<YSYComponentInterfaceProtocol>)openUrlString:(NSString *)urlString parameter:(NSDictionary *)parameter callBack:(YSYCallBack)callBack {
    return [self openUrl:[NSURL URLWithString:urlString] parameter:parameter callBack:callBack];
}

+ (id<YSYComponentInterfaceProtocol>)openUrl:(NSURL *)url parameter:(NSDictionary *)parameter callBack:(YSYCallBack)callBack {
    return [self openUrl:url jumpType:YSYRouterServiceJumpTypePush parameter:parameter callBack:callBack];
}

+ (id<YSYComponentInterfaceProtocol>)openUrlString:(NSString *)urlString jumpType:(YSYRouterServiceJumpType)jumptype {
    return [self openUrlString:urlString jumpType:jumptype parameter:nil callBack:nil];
}

+ (id<YSYComponentInterfaceProtocol>)openUrlString:(NSString *)urlString
                                          jumpType:(YSYRouterServiceJumpType)jumptype
                                         parameter:(NSDictionary *)parameter
                                          callBack:(YSYCallBack)callBack {
    return [self openUrl:[NSURL URLWithString:urlString] jumpType:jumptype parameter:parameter callBack:callBack];
}

+ (id<YSYComponentInterfaceProtocol>)openUrl:(NSURL *)url
                                          jumpType:(YSYRouterServiceJumpType)jumptype
                                         parameter:(NSDictionary *)parameter
                                          callBack:(YSYCallBack)callBack {
    if (!url) {
        return nil;
    }
    /**处理url*/
    NSDictionary *routerParameter = [self analysisUrl:url];
    NSMutableDictionary *dic = routerParameter[YSYRouterParameterUserInfo];
    [dic addEntriesFromDictionary:parameter];
    id<YSYComponentInterfaceProtocol>service = [self callUrl:routerParameter[YSYRouterParameterModuleName]
                                                   parameter:dic
                                                    callBack:callBack];
    SEL action = NSSelectorFromString(routerParameter[YSYRouterParameterAction]);
    // 如果目标模块就是一个 UIViewController 对象
    if ([service isKindOfClass:UIViewController.class] ) {
        if (action && [service respondsToSelector:action]) {
            [self safePerformAction:action module:service parameter:dic];
        }
        if (jumptype == YSYRouterServiceJumpTypePush) {
            [YSYGetTopViewController().navigationController pushViewController:(UIViewController *)service animated:YES];
        } else {
            [YSYGetTopViewController() presentViewController:(UIViewController *)service animated:YES completion:nil];
        }
        return service;
        // 目标组件不是 UIViewController 对象
    } else if (action && [service respondsToSelector:action]) {
        id obj =  [self safePerformAction:action module:service parameter:routerParameter[YSYRouterParameterUserInfo]];
        if ([obj isKindOfClass:UIViewController.class] ) {
            // 一个 导航控制器再 push 进入一个 导航控制器会 系统崩溃
            if (jumptype == YSYRouterServiceJumpTypePush && ![obj isKindOfClass:UINavigationController.class]) {
                [YSYGetTopViewController().navigationController pushViewController: obj animated:YES];
            } else {
                [YSYGetTopViewController() presentViewController:(UIViewController *)obj animated:YES completion:nil];
            }
        }
        return service;
    }
    if (!service) {
        NSLog(@"没有找到路由：%@",url.absoluteString);
    }
    return nil;
}

+ (id<YSYComponentInterfaceProtocol>)callUrl:(NSString *)url callBack:(YSYCallBack)callBack {
    return [self callUrl:url parameter:nil callBack:callBack];
}

+ (id<YSYComponentInterfaceProtocol>)callUrl:(NSString *)url parameter:(NSDictionary *)parameter {
    return [self callUrl:url parameter:parameter callBack:nil];
}

+ (id<YSYComponentInterfaceProtocol>)callUrl:(NSString *)url parameter:(NSDictionary *)parameter callBack:(YSYCallBack)callBack {
    //获取组件
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    id<YSYComponentInterfaceProtocol>module = [self findCache:url];
    if (!module) {
        Class class = [self findUrl:url];
        module = [[class alloc] init];
        
        // 缓存组件,UIViewController 类不缓存
        if (module && ![module isKindOfClass:UIViewController.class]) {
            cacheTable[url] = module;
        }
    }
    if ([module respondsToSelector:@selector(setRouterParameter:)]) {
        module.routerParameter = parameter;
    }
    if ([module respondsToSelector:@selector(setRouterCallBack:)]) {
        module.routerCallBack = callBack;
    }
    dispatch_semaphore_signal(semaphore);
    return module;
}

+ (id<YSYComponentInterfaceProtocol>)findCache:(NSString *)url {
    id<YSYComponentInterfaceProtocol>module = cacheTable[url];
    // 如果没有找到对应的路由，则采用模糊匹配
    if (!module) {
        for (NSString *key in cacheTable.allKeys) {
            if ([url hasPrefix:key]) {
                module = cacheTable[url];
                break;
            }
        }
    }
    return module;
}

+ (Class)findUrl:(NSString *)url {
    Class class = routerTable[url];
    // 如果没有找到对应的路由，则采用模糊匹配
    if (!class) {
        for (NSString *key in routerTable.allKeys) {
            if ([url hasPrefix:key]) {
                class = routerTable[url];
                break;
            }
        }
    }
    return class;
}

#pragma mark -- 工具
+ (NSMutableDictionary *)analysisUrl:(NSURL *)url {
    NSMutableDictionary *urlRouterDic = [NSMutableDictionary dictionary];
    
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    NSString *urlString = [url query];
    for (NSString *param in [urlString componentsSeparatedByString:@"&"]) {
        NSArray *elts = [param componentsSeparatedByString:@"="];
        if([elts count] < 2) continue;
        [params setObject:[elts lastObject] forKey:[elts firstObject]];
    }
    // url格式 scheme://host/module/action?a=1&b=2
    
    // 取出组件路由 scheme://host/module
    urlRouterDic[YSYRouterParameterModuleName] = [NSString stringWithFormat:@"%@://%@", url.scheme, url.host?:@""];
    NSMutableArray *comm = [url.path componentsSeparatedByString:@"/"].mutableCopy;
    [comm removeObject:@""];
    if (comm.count > 0) {
        urlRouterDic[YSYRouterParameterModuleName] = [NSString stringWithFormat:@"%@/%@", urlRouterDic[YSYRouterParameterModuleName], comm.firstObject];
        [comm removeObjectAtIndex:0];
    }
    
    // 取出响应事件方法
    if (comm.count > 0) {
        NSString *actionString = [comm componentsJoinedByString:@"_"];
        urlRouterDic[YSYRouterParameterAction] = [actionString stringByAppendingString:@":"];
    }
   
    // 取出url 后面拼接的参数
    urlRouterDic[YSYRouterParameterUserInfo] = params;
    return urlRouterDic;
}

+ (id)safePerformAction:(SEL)action module:(NSObject *)module parameter:(NSDictionary *)parameter {
    NSMethodSignature* methodSig = [module methodSignatureForSelector:action];
    if(methodSig == nil) {
        return nil;
    }
    const char* retType = [methodSig methodReturnType];
    
    if (strcmp(retType, @encode(void)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&parameter atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:module];
        [invocation invoke];
        return nil;
    }
    
    if (strcmp(retType, @encode(NSInteger)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&parameter atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:module];
        [invocation invoke];
        NSInteger result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }
    
    if (strcmp(retType, @encode(BOOL)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&parameter atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:module];
        [invocation invoke];
        BOOL result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }
    
    if (strcmp(retType, @encode(CGFloat)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&parameter atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:module];
        [invocation invoke];
        CGFloat result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }
    
    if (strcmp(retType, @encode(NSUInteger)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&parameter atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:module];
        [invocation invoke];
        NSUInteger result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }
    
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [module performSelector:action withObject:parameter];
#pragma clang diagnostic pop
}
@end

@implementation UIViewController (YSYRouter)

// 交换视图已经出现的方法
+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method YSYDidappearMethod = class_getInstanceMethod(self, @selector(YSY_ViewDidappear:));
        Method didappearMethod = class_getInstanceMethod(self, @selector(viewDidAppear:));
        method_exchangeImplementations(YSYDidappearMethod, didappearMethod);
    });
}

- (void)YSY_ViewDidappear:(BOOL)animated {
    YSYSetTopViewController(self);
    [self YSY_ViewDidappear:animated];
}

- (id)routerParameter {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setRouterParameter:(id)routerParameter {
    objc_setAssociatedObject(self, @selector(routerParameter), routerParameter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (YSYCallBack)routerCallBack {
    return objc_getAssociatedObject(self, _cmd);
}

- (void)setRouterCallBack:(YSYCallBack)routerCallBack {
    objc_setAssociatedObject(self, @selector(routerCallBack), routerCallBack, OBJC_ASSOCIATION_COPY);
}

@end
