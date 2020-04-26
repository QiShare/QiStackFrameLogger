//
//  QiStackFrameLogger.h
//  QiStackFrameLogger
//
//  Created by liusiqi on 2020/4/24.
//  Copyright © 2020 liusiqi. All rights reserved.
//
// PS: 参考了BestSwifter之前写的BsBacktraceLogger

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define QiLOG_CURRENT NSLog(@"%@",[QiStackFrameLogger qi_backtraceOfCurrentThread]);
#define QiLOG_MAIN NSLog(@"%@",[QiStackFrameLogger qi_backtraceOfMainThread]);
#define QiLOG_ALL NSLog(@"%@",[QiStackFrameLogger qi_backtraceOfAllThread]);

@interface QiStackFrameLogger : NSObject

+ (NSString *)qi_backtraceOfAllThread;                  //!< 打印当前所有线程的堆栈信息
+ (NSString *)qi_backtraceOfCurrentThread;              //!< 打印当前线程的堆栈信息
+ (NSString *)qi_backtraceOfMainThread;                 //!< 打印主线程的堆栈信息
+ (NSString *)qi_backtraceOfNSThread:(NSThread *)thread;//!< 打印指定线程的堆栈信息

@end

NS_ASSUME_NONNULL_END
