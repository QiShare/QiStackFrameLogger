//
//  QiStackFrameLogger.m
//  QiStackFrameLogger
//
//  Created by liusiqi on 2020/4/24.
//  Copyright © 2020 liusiqi. All rights reserved.
//

#import "QiStackFrameLogger.h"
#import <mach/mach.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/types.h>
#include <limits.h>
#include <string.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>

#pragma -mark DEFINE MACRO FOR DIFFERENT CPU ARCHITECTURE
#if defined(__arm64__)
#define DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(3UL))
#define Qi_THREAD_STATE_COUNT ARM_THREAD_STATE64_COUNT
#define Qi_THREAD_STATE ARM_THREAD_STATE64
#define Qi_FRAME_POINTER __fp
#define Qi_STACK_POINTER __sp
#define Qi_INSTRUCTION_ADDRESS __pc

#elif defined(__arm__)
#define DETAG_INSTRUCTION_ADDRESS(A) ((A) & ~(1UL))
#define Qi_THREAD_STATE_COUNT ARM_THREAD_STATE_COUNT
#define Qi_THREAD_STATE ARM_THREAD_STATE
#define Qi_FRAME_POINTER __r[7]
#define Qi_STACK_POINTER __sp
#define Qi_INSTRUCTION_ADDRESS __pc

#elif defined(__x86_64__)
#define DETAG_INSTRUCTION_ADDRESS(A) (A)
#define Qi_THREAD_STATE_COUNT x86_THREAD_STATE64_COUNT
#define Qi_THREAD_STATE x86_THREAD_STATE64
#define Qi_FRAME_POINTER __rbp
#define Qi_STACK_POINTER __rsp
#define Qi_INSTRUCTION_ADDRESS __rip

#elif defined(__i386__)
#define DETAG_INSTRUCTION_ADDRESS(A) (A)
#define Qi_THREAD_STATE_COUNT x86_THREAD_STATE32_COUNT
#define Qi_THREAD_STATE x86_THREAD_STATE32
#define Qi_FRAME_POINTER __ebp
#define Qi_STACK_POINTER __esp
#define Qi_INSTRUCTION_ADDRESS __eip

#endif

#define CALL_INSTRUCTION_FROM_RETURN_ADDRESS(A) (DETAG_INSTRUCTION_ADDRESS((A)) - 1)

#if defined(__LP64__)
#define TRACE_FMT         "%-4d%-31s 0x%016lx %s + %lu"
#define POINTER_FMT       "0x%016lx"
#define POINTER_SHORT_FMT "0x%lx"
#define Qi_NLIST struct nlist_64
#else
#define TRACE_FMT         "%-4d%-31s 0x%08lx %s + %lu"
#define POINTER_FMT       "0x%08lx"
#define POINTER_SHORT_FMT "0x%lx"
#define Qi_NLIST struct nlist
#endif

// 栈帧结构体：
typedef struct QiStackFrameEntry {
    const struct QiStackFrameEntry *const previouts; //!< 上一个栈帧
    const uintptr_t return_address;                  //!< 当前栈帧的地址
} QiStackFrameEntry;

static mach_port_t main_thread_id;

@implementation QiStackFrameLogger

+ (void)load {
    main_thread_id = mach_thread_self();
}

#pragma mark - 对外interface

//! 打印指定线程的堆栈信息
+ (NSString *)qi_backtraceOfNSThread:(NSThread *)thread {
    thread_t machThread = [self qi_getMachThreadFromNSThread:thread];
    return [self qi_backtraceOfThread:machThread];
}

//! 打印当前线程的堆栈信息
+ (NSString *)qi_backtraceOfCurrentThread {
    return [self qi_backtraceOfNSThread:[NSThread currentThread]];
}

//! 打印主线程的堆栈信息
+ (NSString *)qi_backtraceOfMainThread {
    return [self qi_backtraceOfNSThread:[NSThread mainThread]];
}

//! 打印当前所有线程的堆栈信息
+ (NSString *)qi_backtraceOfAllThread {
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount = 0;
    const task_t thisTask = mach_task_self();
    
    kern_return_t kr = task_threads(thisTask, &threads, &threadCount);
    if (kr != KERN_SUCCESS) {
        return @"Fail to get information of all threads.";
    }
    
    NSMutableString *resultString = [NSMutableString stringWithFormat:@"Call Backtrace of %u threads:\n", threadCount];
    for (int i=0; i < threadCount; i++) {
        [resultString appendString:[self qi_backtraceOfThread:threads[i]]];
    }
    return [resultString copy];
}


#pragma mark - 从某个 mach thread 种获取 backtrace

+ (NSString *)qi_backtraceOfThread:(thread_t)thread {
    uintptr_t backtraceBuffer[50];
    int i = 0;
    NSMutableString *resultString = [[NSMutableString alloc] initWithFormat:@"Backtrace of Thread %u:\n", thread];
    
    _STRUCT_MCONTEXT machineContext; // 先声明一个context，再从thread中取出context
    if(![self qi_fillThreadStateFrom:thread intoMachineContext:&machineContext]) {
        return [NSString stringWithFormat:@"Fail to get machineContext from thread: %u\n", thread];
    }
    
    const uintptr_t instructionAddress = qi_mach_instructionAddress(&machineContext);
    backtraceBuffer[i++] = instructionAddress;
    
    uintptr_t linkRegister = qi_mach_linkRegister(&machineContext);
    if (linkRegister) {
        backtraceBuffer[i++] = linkRegister;
    }
    
    if (instructionAddress == 0) {
        return @"Fail to get instructionAddress.";
    }
    
    QiStackFrameEntry frame = {0};
    const uintptr_t framePointer = qi_mach_framePointer(&machineContext);
    if (framePointer == 0 || qi_mach_copyMem((void *)framePointer, &frame, sizeof(frame)) != KERN_SUCCESS) {
        return @"Fail to get frame pointer";
    }
    // 对frame进行赋值
    
    for (; i<50; i++) {
        backtraceBuffer[i] = frame.return_address; // 把当前的地址保存
        if (backtraceBuffer[i] == 0 || frame.previouts == 0 || qi_mach_copyMem(frame.previouts, &frame, sizeof(frame)) != KERN_SUCCESS) {
            break; // 找到原始帧，就break
        }
    }
    
    int backtraceLength = i;
    Dl_info symbolicated[backtraceLength];
    qi_symbolicate(backtraceBuffer, symbolicated, backtraceLength, 0);
    for (int i = 0; i < backtraceLength; i++) {
        [resultString appendFormat:@"%@", [self qi_logBackTraceEntryWithNum:i address:backtraceBuffer[i] dlInfo:&symbolicated[i]]];
    }
    [resultString appendFormat:@"\n"];
    
    return  [resultString copy];
}


#pragma mark - Handle Machine Context

/*!
 @brief 将machineContext从thread中提取出来
 @param thread 当前线程
 @param machineContext 所要赋值的machineContext
 @return 是否获取成功
 */
+ (BOOL) qi_fillThreadStateFrom:(thread_t) thread intoMachineContext:(_STRUCT_MCONTEXT *)machineContext {
    mach_msg_type_number_t state_count = Qi_THREAD_STATE_COUNT;
    kern_return_t kr = thread_get_state(thread, Qi_THREAD_STATE, (thread_state_t)&machineContext->__ss, &state_count);
    return kr == KERN_SUCCESS;
}

uintptr_t qi_mach_framePointer(mcontext_t const machineContext) {
    return machineContext->__ss.Qi_FRAME_POINTER;
}

uintptr_t qi_mach_stackPointer(mcontext_t const machineContext) {
    return machineContext->__ss.Qi_STACK_POINTER;
}

uintptr_t qi_mach_instructionAddress(mcontext_t const machineContext) {
    return machineContext->__ss.Qi_INSTRUCTION_ADDRESS;
}

uintptr_t qi_mach_linkRegister(mcontext_t const machineContext) {
#if defined(__i386__) || defined(__x86_64__)
    return 0;
#else
    return machineContext->__ss.__lr;
#endif
}

kern_return_t qi_mach_copyMem(const void *const src,
                              void *const dst,
                              const size_t numBytes) {
    vm_size_t bytesCopied = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)src, (vm_size_t)numBytes, (vm_address_t)dst, &bytesCopied);
}


#pragma mark - Symbolicate

// 符号化：将backtraceBuffer转成symbolsBuffer。
void qi_symbolicate(const uintptr_t* const backtraceBuffer,
                    Dl_info* const symbolsBuffer,
                    const int numEntries,
                    const int skippedEntries) {
    int i = 0;
    
    if(!skippedEntries && i < numEntries) {
        qi_dladdr(backtraceBuffer[i], &symbolsBuffer[i]); //通过回溯得到的栈帧，找到对应的符号名。
        i++;
    }
    
    for (; i < numEntries; i++) {
        qi_dladdr(CALL_INSTRUCTION_FROM_RETURN_ADDRESS(backtraceBuffer[i]), &symbolsBuffer[i]);
    }
}

// 通过address得到当前函数info信息，包括：dli_fname、dli_fbase、dli_saddr、dli_sname.
bool qi_dladdr(const uintptr_t address, Dl_info* const info) {
    info->dli_fname = NULL;
    info->dli_fbase = NULL;
    info->dli_saddr = NULL;
    info->dli_sname = NULL;
    
    const uint32_t index = qi_getImageIndexContainingAddress(address); // 根据地址找到image中的index。
    if (index == UINT_MAX) {
        return false; // 没找到就返回UINT_MAX
    }
    
    /*
     Header
     ------------------
     Load commands
     Segment command 1 -------------|
     Segment command 2              |
     ------------------             |
     Data                           |
     Section 1 data |segment 1 <----|
     Section 2 data |          <----|
     Section 3 data |          <----|
     Section 4 data |segment 2
     Section 5 data |
     ...            |
     Section n data |
     */
    /*----------Mach Header---------*/
    const struct mach_header *header = _dyld_get_image_header(index); // 根据index找到header
    const uintptr_t imageVMAddrSlide = (uintptr_t)_dyld_get_image_vmaddr_slide(index); //image虚拟内存地址
    const uintptr_t addressWithSlide = address - imageVMAddrSlide; // ASLR偏移量
    const uintptr_t segmentBase = qi_getSegmentBaseAddressOfImageIndex(index) + imageVMAddrSlide; // segmentBase是根据index + ASLR得到的
    if (segmentBase == 0) {
        return false;
    }
    
    info->dli_fname = _dyld_get_image_name(index);
    info->dli_fbase = (void *)header;
    
    // 查找符号表，找到对应的符号
    const Qi_NLIST* bestMatch = NULL;
    uintptr_t bestDistace = ULONG_MAX;
    uintptr_t cmdPointer = qi_firstCmdAfterHeader(header);
    if (cmdPointer == 0) {
        return false;
    }
    for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
        const struct load_command* loadCmd = (struct load_command*)cmdPointer;
        if (loadCmd->cmd == LC_SYMTAB) {
            const struct symtab_command *symtabCmd = (struct symtab_command*)cmdPointer;
            const Qi_NLIST* symbolTable = (Qi_NLIST*)(segmentBase + symtabCmd->symoff);
            const uintptr_t stringTable = segmentBase + symtabCmd->stroff;
            
            /*
             *
             struct symtab_command {
                 uint32_t    cmd;        / LC_SYMTAB /
                 uint32_t    cmdsize;    / sizeof(struct symtab_command) /
                 uint32_t    symoff;     / symbol table offset 符号表偏移 /
                 uint32_t    nsyms;      / number of symbol table entries 符号表条目的数量 /
                 uint32_t    stroff;     / string table offset 字符串表偏移 /
                 uint32_t    strsize;    / string table size in bytes 字符串表的大小(以字节为单位) /
             };
             */
            
            for (uint32_t iSym = 0; iSym < symtabCmd->nsyms; iSym++) {
                // 如果n_value为0，则该符号引用一个外部对象。
                if (symbolTable[iSym].n_value != 0) {
                    uintptr_t symbolBase = symbolTable[iSym].n_value;
                    uintptr_t currentDistance = addressWithSlide - symbolBase;
                    if ((addressWithSlide >= symbolBase) && (currentDistance <= bestDistace)) {
                        bestMatch = symbolTable + iSym;
                        bestDistace = currentDistance;
                    }
                }
            }
            if (bestMatch != NULL) {
                info->dli_saddr = (void*)(bestMatch->n_value + imageVMAddrSlide);
                info->dli_sname = (char*)((intptr_t)stringTable + (intptr_t)bestMatch->n_un.n_strx);
                if (*info->dli_sname == '_') {
                    info->dli_sname++;
                }
                //如果所有的符号都被删除，就会发生这种情况。
                if (info->dli_saddr == info->dli_fbase && bestMatch->n_type == 3) {
                    info->dli_sname = NULL;
                }
                break;
            }
        }
        cmdPointer += loadCmd->cmdsize;
    }
    return true;
}

// 找出address所对应的image编号
uint32_t qi_getImageIndexContainingAddress(const uintptr_t address) {
    const uint32_t imageCount = _dyld_image_count(); // dyld中image的个数
    const struct mach_header *header = 0;
    
    for (uint32_t i = 0; i < imageCount; i++) {
        header = _dyld_get_image_header(i);
        if (header != NULL) {
            // 在提供的address范围内，寻找segment command
            uintptr_t addressWSlide = address - (uintptr_t)_dyld_get_image_vmaddr_slide(i); //!< ASLR
            uintptr_t cmdPointer = qi_firstCmdAfterHeader(header);
            if (cmdPointer == 0) {
                continue;
            }
            for (uint32_t iCmd = 0; iCmd < header->ncmds; iCmd++) {
                const struct load_command *loadCmd = (struct load_command*)cmdPointer;
                if (loadCmd->cmd == LC_SEGMENT) {
                    const struct segment_command *segCmd = (struct segment_command*)cmdPointer;
                    if (addressWSlide >= segCmd->vmaddr && addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        // 命中!
                        return i;
                    }
                }
                else if (loadCmd->cmd == LC_SEGMENT_64) {
                    const struct segment_command_64 *segCmd = (struct segment_command_64*)cmdPointer;
                    if (addressWSlide >= segCmd->vmaddr && addressWSlide < segCmd->vmaddr + segCmd->vmsize) {
                        // 命中!
                        return i;
                    }
                }
                cmdPointer += loadCmd->cmdsize;
            }
        }
    }
    
    return UINT_MAX; // 没找到就返回UINT_MAX
}

// 根据image的index，查找segment command并返回iamge的address。
uintptr_t qi_getSegmentBaseAddressOfImageIndex(const uint32_t index) {
    const struct mach_header *header = _dyld_get_image_header(index); // 根据index取到对应的image header
    
    // 根据image的index，查找segment command并返回iamge的address。
    uintptr_t cmdPointer = qi_firstCmdAfterHeader(header);
    if (cmdPointer == 0) {
        return 0;
    }
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *loadCmd = (struct load_command*)cmdPointer;
        if (loadCmd->cmd == LC_SEGMENT) {
            const struct segment_command *segmentCmd = (struct segment_command*)cmdPointer;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return segmentCmd->vmaddr - segmentCmd->fileoff; // 返回地址
            }
        }
        else if (loadCmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segmentCmd = (struct segment_command_64*)cmdPointer;
            if (strcmp(segmentCmd->segname, SEG_LINKEDIT) == 0) {
                return (uintptr_t)(segmentCmd->vmaddr - segmentCmd->fileoff);
            }
        }
        cmdPointer += loadCmd->cmdsize; //遍历查找下一个段
    }
    return 0;
}

// 根据不同的架构，返回不同的header初始值
uintptr_t qi_firstCmdAfterHeader(const struct mach_header* const header) {
    switch (header->magic) {
        case MH_MAGIC:
        case MH_CIGAM:
            return (uintptr_t)(header + 1); // 32位架构
        case MH_MAGIC_64:
        case MH_CIGAM_64:
            return (uintptr_t)(((struct mach_header_64*)header) + 1); // 64位架构
            
        default:
            return 0; // header is corrupt
    }
}


#pragma mark - 把 NSThread 转成 mach thread

+ (thread_t)qi_getMachThreadFromNSThread:(NSThread *)thread {
    char name[256];
    mach_msg_type_number_t count;
    thread_act_array_t threads;
    task_threads(mach_task_self(), &threads, &count); //!< 拿到当前所有的线程信息
    
    NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
    NSString *originName = [thread name]; //记录之前thread的name
    [thread setName:[NSString stringWithFormat:@"%f", currentTimestamp]];
    
    if([thread isMainThread]) {
        return (thread_t)main_thread_id;
    }
    
    for (int i=0; i<count; ++i) {
        pthread_t pt = pthread_from_mach_thread_np(threads[i]);
        if ([thread isMainThread]) {
            if (threads[i] == main_thread_id) {
                return threads[i];
            }
        }
        if (pt) {
            name[0] = '\0';
            pthread_getname_np(pt, name, sizeof(name));
            if (!strcmp(name, [thread name].UTF8String)) {
                [thread setName:originName];
                return threads[i];
            }
        }
    }
    [thread setName:originName];
    return mach_thread_self();
}


#pragma mark - 生成日志

/*!
 @brief 生成日志
 @param entryNum 符号编号
 @param address 符号地址
 @param dlInfo 符号信息
 @return Log
 */
+ (NSString *)qi_logBackTraceEntryWithNum: (const int) entryNum
                                  address: (const uintptr_t) address
                                   dlInfo: (const Dl_info* const) dlInfo {
    char faddrBuff[20];
    char saddrBuff[20];
    
    const char* fname = qi_lastPathEntry(dlInfo->dli_fname);
    if (fname == NULL) {
        sprintf(faddrBuff, POINTER_FMT, (uintptr_t)dlInfo->dli_fbase);
        fname = faddrBuff;
    }
    
    uintptr_t offset = address - (uintptr_t)dlInfo->dli_saddr;
    const char* sname = dlInfo->dli_sname;
    if (sname == NULL) {
        sprintf(saddrBuff, POINTER_SHORT_FMT, (uintptr_t)dlInfo->dli_fbase);
        sname = saddrBuff;
        offset = address - (uintptr_t)dlInfo->dli_fbase;
    }
    return [NSString stringWithFormat:@"%-30s  0x%08" PRIxPTR " %s + %lu\n" ,fname, (uintptr_t)address, sname, offset];
}

const char* qi_lastPathEntry(const char* const path) {
    if (path == NULL) {
        return NULL;
    }
    char* lastFile = strrchr(path, '/');
    return lastFile == NULL ? path : lastFile + 1;
}

@end
