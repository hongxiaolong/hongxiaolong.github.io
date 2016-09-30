---
layout: post
title: Linux内核源码分析：文件锁
category: tech
---

# 前言

在Linux内核中，锁是很常见的同步机制，比如critical section(临界区)、mutex（互斥量）、semaphore（信号量）、event（事件，Windows内核常见）等等等，都可以用来保证共享资源的互斥访问。

在多进程、多线程场景下，简单总结如下：

- Critical Section（临界区）：只能用来同步多个线程间的互斥访问，不能跨进程同步。开销小，效率高；

- Mutex（互斥量）：可以跨线程和进程使用，相比临界区，创建互斥量需要更多的资源

    *（Linux和Windows的互斥量虽然都可以跨进程使用，但前者要通过共享内存使用，后者则使用命名互斥量即可）*

- Semaphore（信号量）：Linux中的信号量*是一种睡眠锁（比对自旋锁），*可以跨线程和进程使用，它的特点是可以用来保证多个资源的互斥访问；

- Event（事件）：Linux的事件机制如epoll等，也可以用来跨线程和进程使用，但和Windows内核可以使用事件对象保证资源互斥的机制还是有所不同的；

资源有很多种，不过在Linux系统中，有一种最重要的资源 -- 文件，针对文件资源的互斥访问，Linux内核提供了更高级别的锁 -- 文件锁。

*前言部分其实仅仅是为了回忆和总结脑海中的几个概念而已..如有兴趣，请自行检索~~*


# Linux下的文件锁

Linux下多进程同时读写同一个文件的场景十分常见，为了保证这种场景下文件内容的一致性，Linux内核提供了2种特殊的系统调用 -- "flock"和"lockf"。

"flock"可以实现对整个文件的加锁，而"lockf"则是另一个系统调用"fcntl"的再封装，它可以实现对文件部分字节加锁，比"flock"的粒度要细。

"flock"的使用方式可以直接参考对应的shell命令flock：

~~~

# man flock

NAME
       flock - manage locks from shell scripts

SYNOPSIS
       flock [options] <file|directory> <command> [command args]
       flock [options] <file|directory> -c <command>
       flock [options] <file descriptor number>

DESCRIPTION
       This utility manages flock(2) locks from within shell scripts or the command line.

       The  first  and second forms wrap the lock around the executing a command, in a manner similar to su(1) or newgrp(1).  It locks a specified file or directory, which is created (assuming appropriate
       permissions), if it does not already exist.  By default, if the lock cannot be immediately acquired, flock waits until the lock is available.

       The third form uses open file by file descriptor number.  See examples how that can be used.

OPTIONS
       -s, --shared
              Obtain a shared lock, sometimes called a read lock.

       -x, -e, --exclusive
              Obtain an exclusive lock, sometimes called a write lock.  This is the default.

       -u, --unlock
              Drop a lock.  This is usually not required, since a lock is automatically dropped when the file is closed.  However, it may be required in special cases, for example if the enclosed  command
              group may have forked a background process which should not be holding the lock.

       -n, --nb, --nonblock
              Fail rather than wait if the lock cannot be immediately acquired.  See the -E option for the exit code used.

       -w, --wait, --timeout seconds
              Fail if the lock cannot be acquired within seconds.  Decimal fractional values are allowed.  See the -E option for the exit code used.

       -o, --close
              Close the file descriptor on which the lock is held before executing command .  This is useful if command spawns a child process which should not be holding the lock.

       -E, --conflict-exit-code number
              The exit code used when the -n option is in use, and the conflicting lock exists, or the -w option is in use, and the timeout is reached. The default value is 1.

       -c, --command command
              Pass a single command, without arguments, to the shell with -c.

       -h, --help
              Print a help message.

       -V, --version
              Show version number and exit.

~~~

很明显，flock针对的资源单位是"file\|directory"，而在Linux系统中，directory（目录）也是一种文件，它们均对应于文件系统中的inode。

现在我们可以从inode开始分析内核源码，找到flock相关的调用栈。

Linux文件锁（"struct file_lock"）是作为inode结构体对应的"i_flock"字段存在的，"i_flock"其实是个链表，后面会提到。

~~~

/* 本文的内核源码版本为linux-3.10.103 */

/* linux-3.10.103/linux-3.10.103/include/linux/fs.h */

struct inode {
    ...

    struct file_lock    *i_flock;

    ...
}


~~~

我们再从"struct file_lock"入手，源码如下：

~~~

/* linux-3.10.103/linux-3.10.103/include/linux/fs.h */

struct file_lock {
    struct file_lock *fl_next;    /* singly linked list for this inode  */
    struct list_head fl_link;    /* doubly linked list of all locks */
    struct list_head fl_block;    /* circular list of blocked processes */
    fl_owner_t fl_owner;
    unsigned int fl_flags;
    unsigned char fl_type;
    unsigned int fl_pid;
    struct pid *fl_nspid;
    wait_queue_head_t fl_wait;
    struct file *fl_file;
    loff_t fl_start;
    loff_t fl_end;

    struct fasync_struct *    fl_fasync; /* for lease break notifications */
    /* for lease breaks: */
    unsigned long fl_break_time;
    unsigned long fl_downgrade_time;

    const struct file_lock_operations *fl_ops;    /* Callbacks for filesystems */
    const struct lock_manager_operations *fl_lmops;    /* Callbacks for lockmanagers */
    union {
        struct nfs_lock_info    nfs_fl;
        struct nfs4_lock_info    nfs4_fl;
        struct {
            struct list_head link;    /* link in AFS vnode's pending_locks list */
            int state;        /* state of grant or error if -ve */
        } afs;
    } fl_u;
};

~~~

每个"file_lock"对象都代表着某个文件锁，其中的"fl_file"字段就指向需要加锁的文件资源对象。

"file_lock"的关键字段定义了该文件锁的关键信息，它们的描述可以参见下表。

| 类型                            | 字段          | 字段描述                         |
|:-------------------------------:|:-------------:|:--------------------------------:|
|struct file_lock*                |fl_next        |与索引节点相关的锁列表中下一个元素|
|struct list_head                 |fl_link        |指向活跃列表或者被阻塞列表        |
|struct list_head                 |fl_block       |指向锁等待列表                    |
|struct files_struct *            |fl_owner       |锁拥有者的 files_struct           |
|unsigned char                    |fl_flags       |锁标识                            |
|unsigned char                    |fl_type        |锁类型                            |
|unsigned int                     |fl_pid         |进程拥有者的 pid                  |
|wait_queue_head_t                |fl_wait        |被阻塞进程的等待队列              |
|struct file *                    |fl_file        |指向文件对象                      |
|loff_t                           |fl_start       |被锁区域的开始位移                |
|loff_t                           |fl_end         |被锁区域的结束位移                |
|struct fasync_struct *           |fl_fasync      |用于租借暂停通知                  |
|unsigned long                    |fl_break_time  |租借的剩余时间                    |
|struct file_lock_operations *    |fl_ops         |指向文件锁操作                    |
|struct lock_manager_operations * |fl_mops        |指向锁管理操作                    |
|union                            |fl_u           |文件系统特定信息                  |

OK，现在我们已经知道inode和文件锁（"struct file_lock"）的关联关系。而在Linux内核中，inode和文件一一对应，每个文件都对应内存中唯一的"struct inode"对象。

当不同进程打开同一个文件时（"open()"系统调用），尽管每个进程都会单独实例化一个"struct file"对象，但他们都指向同一个inode。

~~~

/* linux-3.10.103/linux-3.10.103/include/linux/fs.h */

struct file {
    ...

    struct inode        *f_inode;    /* cached value */

    ...
}

/* linux-3.10.103/linux-3.10.103/fs/open.c */

long do_sys_open(int dfd, const char __user *filename, int flags, umode_t mode)
{
    struct open_flags op;
    int lookup = build_open_flags(flags, mode, &op);
    struct filename *tmp = getname(filename);
    int fd = PTR_ERR(tmp);

    if (!IS_ERR(tmp)) {
        fd = get_unused_fd_flags(flags);
        if (fd >= 0) {
            struct file *f = do_filp_open(dfd, tmp, &op, lookup);
            if (IS_ERR(f)) {
                put_unused_fd(fd);
                fd = PTR_ERR(f);
            } else {
                fsnotify_open(f);
                fd_install(fd, f);
            }
        }
        putname(tmp);
    }
    return fd;
}

~~~

在"open()"系统调用中，"do_sys_open()"通过"do_filp_open()"实例化了一个"struct file"对象，"do_sys_open()"的返回值"fd"（文件描述符）一般只在该进程中独立存在，被调用以完成该文件的读写操作。即使不同的进程打开相同的文件，它们的"fd"（文件描述符）也是不同的。

分析到这里，我们已经可以很清晰地明白文件和文件锁的源码层次了，也可以轻易地以如下关联箭头回溯：

**"fd" => "struct file" => "struct inode" => "struct file_lock"**


# flock


不管是上面提到的shell命令flock，还是flock()的函数原型：

~~~
int flock(int fd, int operation);
~~~

最终在Linux的内核源码中都是系统调用"sys_flock()"。

我们从源码分析"sys_flock()"。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/**
 *    sys_flock: - flock() system call.
 *    @fd: the file descriptor to lock.
 *    @cmd: the type of lock to apply.
 *
 *    Apply a %FL_FLOCK style lock to an open file descriptor.
 *    The @cmd can be one of
 *
 *    %LOCK_SH -- a shared lock.
 *
 *    %LOCK_EX -- an exclusive lock.
 *
 *    %LOCK_UN -- remove an existing lock.
 *
 *    %LOCK_MAND -- a `mandatory' flock.  This exists to emulate Windows Share Modes.
 *
 *    %LOCK_MAND can be combined with %LOCK_READ or %LOCK_WRITE to allow other
 *    processes read and write access respectively.
 */
SYSCALL_DEFINE2(flock, unsigned int, fd, unsigned int, cmd)
{
    struct fd f = fdget(fd);
    struct file_lock *lock;
    int can_sleep, unlock;
    int error;

    error = -EBADF;
    if (!f.file)
        goto out;

    can_sleep = !(cmd & LOCK_NB);
    cmd &= ~LOCK_NB;
    unlock = (cmd == LOCK_UN);

    if (!unlock && !(cmd & LOCK_MAND) &&
        !(f.file->f_mode & (FMODE_READ|FMODE_WRITE)))
        goto out_putf;

    error = flock_make_lock(f.file, &lock, cmd);
    if (error)
        goto out_putf;
    if (can_sleep)
        lock->fl_flags |= FL_SLEEP;

    error = security_file_lock(f.file, lock->fl_type);
    if (error)
        goto out_free;

    if (f.file->f_op && f.file->f_op->flock)
        error = f.file->f_op->flock(f.file,
                      (can_sleep) ? F_SETLKW : F_SETLK,
                      lock);
    else
        error = flock_lock_file_wait(f.file, lock);

 out_free:
    locks_free_lock(lock);

 out_putf:
    fdput(f);
 out:
    return error;
}

~~~

内核通过"sys_flock()"的入参"fd"和"fdget()"，可以定位得到其指向的文件对象"struct file"。

"sys_flock()"的核心在于"flock_lock_file_wait()"。在Ext4文件系统中，我们最终都会走到这段代码，因为Ext4并没有指定"f.file->f_op->flock"字段。

化繁为简，我们还是直接关注"flock_lock_file_wait()"吧。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/**
 * flock_lock_file_wait - Apply a FLOCK-style lock to a file
 * @filp: The file to apply the lock to
 * @fl: The lock to be applied
 *
 * Add a FLOCK style lock to a file.
 */
int flock_lock_file_wait(struct file *filp, struct file_lock *fl)
{
    int error;
    might_sleep();
    for (;;) {
        error = flock_lock_file(filp, fl);
        if (error != FILE_LOCK_DEFERRED)
            break;
        error = wait_event_interruptible(fl->fl_wait, !fl->fl_next);
        if (!error)
            continue;

        locks_delete_block(fl);
        break;
    }
    return error;
}

~~~

又是很明显的.."flock_lock_file_wait()"的核心逻辑在于"flock_lock_file()"，因为文件锁的层次关系"fd" => "file" => "inode" => "file_lock"，我们还缺少最重要的一环"inode"。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/* Try to create a FLOCK lock on filp. We always insert new FLOCK locks
 * after any leases, but before any posix locks.
 *
 * Note that if called with an FL_EXISTS argument, the caller may determine
 * whether or not a lock was successfully freed by testing the return
 * value for -ENOENT.
 */
static int flock_lock_file(struct file *filp, struct file_lock *request)
{
    struct file_lock *new_fl = NULL;
    struct file_lock **before;
    struct inode * inode = file_inode(filp);
    int error = 0;
    int found = 0;

    if (!(request->fl_flags & FL_ACCESS) && (request->fl_type != F_UNLCK)) {
        new_fl = locks_alloc_lock();
        if (!new_fl)
            return -ENOMEM;
    }

    lock_flocks();
    if (request->fl_flags & FL_ACCESS)
        goto find_conflict;

    for_each_lock(inode, before) {
        struct file_lock *fl = *before;
        if (IS_POSIX(fl))
            break;
        if (IS_LEASE(fl))
            continue;
        if (filp != fl->fl_file)
            continue;
        if (request->fl_type == fl->fl_type)
            goto out;
        found = 1;
        locks_delete_lock(before);
        break;
    }

    if (request->fl_type == F_UNLCK) {
        if ((request->fl_flags & FL_EXISTS) && !found)
            error = -ENOENT;
        goto out;
    }

    /*
     * If a higher-priority process was blocked on the old file lock,
     * give it the opportunity to lock the file.
     */
    if (found) {
        unlock_flocks();
        cond_resched();
        lock_flocks();
    }

find_conflict:
    for_each_lock(inode, before) {
        struct file_lock *fl = *before;
        if (IS_POSIX(fl))
            break;
        if (IS_LEASE(fl))
            continue;
        if (!flock_locks_conflict(request, fl))
            continue;
        error = -EAGAIN;
        if (!(request->fl_flags & FL_SLEEP))
            goto out;
        error = FILE_LOCK_DEFERRED;
        locks_insert_block(fl, request);
        goto out;
    }
    if (request->fl_flags & FL_ACCESS)
        goto out;
    locks_copy_lock(new_fl, request);
    locks_insert_lock(before, new_fl);
    new_fl = NULL;
    error = 0;

out:
    unlock_flocks();
    if (new_fl)
        locks_free_lock(new_fl);
    return error;
}

~~~

果然，在"flock_lock_file()"中，我们通过"struct file"找到了该文件资源对应的"inode"。

分析完flock的调用栈后，我们已经找到了文件锁的枝干，剩下的无非就是对于这把锁的增删改查等细枝末节*（细节才最熬人..）*而已。

"flock_lock_file()"的源码注释也为我们解释了，它的加锁机制是释放原有的锁后再新建一把新的文件锁。

"lock_flocks()"里有"spinlock"的相关逻辑，这里的自旋锁用来保证"inode"数据访问的同步，当增删改查完成后"unlock_flocks()"将释放该把自旋锁。

"for_each_lock()"会去遍历"inode->i_flock"这个链表，那么为啥这里要搞个链表来存文件锁呢？

原因是因为flock归根到底还是个建议锁，它不要求进程一定要遵守，当一个进程对某个文件使用了文件锁，但是另一个进程却压根不去检查该文件是否已经存在文件锁，霸道地直接读写文件内容，事实上内核并不会阻止。所以，flock有效的前提是大家都遵守同样的锁规则，在读写文件前都需要提前去检查一下是否某个进程还持有着文件锁。当然，为了功能性考虑，flock还是支持LOCK_SH（共享锁）和LOCK_EX（排他锁）多种模式的，于是，用一个链表来存储不同进程的共享锁自然很有必要。

我们可以来看一段flock的测试代码。

~~~

/* flock.c */

#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <wait.h>

#define PATH "/tmp/lock"

int main() {
    int fd;
    pid_t pid;

    fd = open(PATH, O_RDWR|O_CREAT|O_TRUNC, 0644);
    if (fd < 0) {
        perror("open()");
        exit(1);
    }

    if (flock(fd, LOCK_SH) < 0) {
        perror("flock()");
        exit(1);
    }
    printf("%d: locked!\n", getpid());

    pid = fork();
    if (pid < 0) {
        perror("fork()");
        exit(1);
    }

    if (pid == 0) {

         fd = open(PATH, O_RDWR|O_CREAT|O_TRUNC, 0644);
         if (fd < 0) {
             perror("open()");
             exit(1);
         }

        if (flock(fd, LOCK_SH) < 0) {
            perror("flock()");
            exit(1);
        }
        printf("%d: locked!\n", getpid());
        exit(0);
    }
    wait(NULL);
    unlink(PATH);
    exit(0);
}

# gcc flock.c -o flock

# ./flock
11205: locked!
11206: locked!

~~~

可以看到，flock的LOCK_SH（共享锁）模式支持多个进程对同一个文件的同时加锁。

也可以把LOCK_SH（共享锁）改成LOCK_EX（排他锁），结果自然是不一样的，因为排他锁同时只能有一个进程持有，在释放前其它进程想要获得则会阻塞。

上面的代码中，"fork()"后子进程会继承父进程的"fd"，如果不重新执行"open()"，也会有不同的结果，有兴趣的可以自己尝试。

# lockf

通过分析"flock"的源码实现，我们已经知道"flock"可以支持文件资源的互斥访问，它作为文件锁可以锁定整个文件。

"lockf"则是另一个系统调用"fcntl"的再封装，它可以实现对文件部分字节加锁。

相比"flock"，"lockf"（下文全部使用"fcntl"）的粒度更细，所以也可以称其为"记录锁"。

同样的，"fcntl"也提供shell命令的使用方式：

~~~

# man fcntl

NAME
    Fcntl - load the C Fcntl.h defines

SYNOPSIS
    use Fcntl;
    use Fcntl qw(:DEFAULT :flock);

DESCRIPTION
    This module is just a translation of the C fcntl.h file.  Unlike the old mechanism of requiring a translated fcntl.ph file, this uses the h2xs program (see the Perl source distribution) and your
    native C compiler.  This means that it has a far more likely chance of getting the numbers right.

~~~

"fcntl()"的函数原型：

~~~
int fcntl(int fd, int cmd, ... /* arg */ );
~~~

这一切都和"flock"很相似，的确，在内核源码上，两者的枝干也十分相似。

"fcntl"的源码层次关系也基本如下所示：

**"fd" => "struct file" => "struct inode" => "struct file_lock"**

不过为了增加更细粒度的针对文件部分字节的文件锁，"fcntl"增加了新的"struct flock"对象。

~~~

/* linux-3.10.103/linux-3.10.103/include/uapi/asm-generic/fcntl.h */

struct flock {
    short    l_type;
    short    l_whence;
    __kernel_off_t    l_start;
    __kernel_off_t    l_len;
    __kernel_pid_t    l_pid;
    __ARCH_FLOCK_PAD
};

~~~

"flock"的关键字段定义了记录锁锁的关键信息，它们的描述可以参见下表。

| 类型                            | 字段          | 字段描述                         |
|:-------------------------------:|:-------------:|:--------------------------------:|
|short                            |l_type         |锁的类型                          |
|short                            |l_whence       |指向文件的加锁区域                |
|__kernel_off_t                   |l_start        |指向文件的加锁区域                |
|__kernel_off_t                   |l_len          |指向文件的加锁区域字节长度        |
|__kernel_pid_t                   |l_pid          |锁的拥有者                        |

我们也从"fcntl"的系统调用"do_fcntl()"开始分析。

~~~

/* linux-3.10.103/linux-3.10.103/fs/fcntl.c */

static long do_fcntl(int fd, unsigned int cmd, unsigned long arg,
        struct file *filp)
{
    ...

    case F_GETLK:
        err = fcntl_getlk(filp, (struct flock __user *) arg);
        break;
    case F_SETLK:
    case F_SETLKW:
        err = fcntl_setlk(fd, filp, cmd, (struct flock __user *) arg);
        break;

    ...
}

~~~

"do_fcntl()"通过"fcntl"传递的操作类型F_GETLK、F_SETLK或者F_SETLKW来决定真正的调用栈路径。

F_GETLK用来查询文件的锁信息，F_SETLK和F_SETLKW用来对文件的某些字节执行加锁操作。

"fcntl_setlk()"接收入参"fd"和"filp"，前者是文件描述符，后者是"struct file"对象。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/* Apply the lock described by l to an open file descriptor.
 * This implements both the F_SETLK and F_SETLKW commands of fcntl().
 */
int fcntl_setlk(unsigned int fd, struct file *filp, unsigned int cmd,
        struct flock __user *l)
{
    struct file_lock *file_lock = locks_alloc_lock();
    struct flock flock;
    struct inode *inode;
    struct file *f;
    int error;

    ...

    inode = file_inode(filp);

    ...

    error = flock_to_posix_lock(filp, file_lock, &flock);
    if (error)
        goto out;

    ...

    error = do_lock_file_wait(filp, cmd, file_lock);

    /*
     * Attempt to detect a close/fcntl race and recover by
     * releasing the lock that was just acquired.
     */
    if (!error && file_lock->fl_type != F_UNLCK) {
        /*
         * We need that spin_lock here - it prevents reordering between
         * update of inode->i_flock and check for it done in
         * close(). rcu_read_lock() wouldn't do.
         */
        spin_lock(&current->files->file_lock);
        f = fcheck(fd);
        spin_unlock(&current->files->file_lock);
        if (f != filp) {
            file_lock->fl_type = F_UNLCK;
            error = do_lock_file_wait(filp, cmd, file_lock);
            WARN_ON_ONCE(error);
            error = -EBADF;
        }
    }
out:
    locks_free_lock(file_lock);
    return error;
}

~~~

继续分析"fcntl_setlk"的源码，记录锁的层次关系"fd" => "file" => "inode" => "file_lock" => "flock"都已齐备，该函数的核心在于"flock_to_posix_lock()"和"do_lock_file_wait()"。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/* Verify a "struct flock" and copy it to a "struct file_lock" as a POSIX
 * style lock.
 */
static int flock_to_posix_lock(struct file *filp, struct file_lock *fl,
                   struct flock *l)
{
    off_t start, end;

    switch (l->l_whence) {
    case SEEK_SET:
        start = 0;
        break;
    case SEEK_CUR:
        start = filp->f_pos;
        break;
    case SEEK_END:
        start = i_size_read(file_inode(filp));
        break;
    default:
        return -EINVAL;
    }

    /* POSIX-1996 leaves the case l->l_len < 0 undefined;
       POSIX-2001 defines it. */
    start += l->l_start;
    if (start < 0)
        return -EINVAL;
    fl->fl_end = OFFSET_MAX;
    if (l->l_len > 0) {
        end = start + l->l_len - 1;
        fl->fl_end = end;
    } else if (l->l_len < 0) {
        end = start - 1;
        fl->fl_end = end;
        start += l->l_len;
        if (start < 0)
            return -EINVAL;
    }
    fl->fl_start = start;    /* we record the absolute position */
    if (fl->fl_end < fl->fl_start)
        return -EOVERFLOW;
    
    fl->fl_owner = current->files;
    fl->fl_pid = current->tgid;
    fl->fl_file = filp;
    fl->fl_flags = FL_POSIX;
    fl->fl_ops = NULL;
    fl->fl_lmops = NULL;

    return assign_type(fl, l->l_type);
}

~~~

"flock_to_posix_lock()"的逻辑还是比较简单的，它其实就是内核针对文件字节加锁的区间计算。

我们接着来看"do_lock_file_wait()"的逻辑，它的作用和"flock"的"flock_lock_file_wait()"也大体相同。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

static int do_lock_file_wait(struct file *filp, unsigned int cmd,
                 struct file_lock *fl)
{
    int error;

    error = security_file_lock(filp, fl->fl_type);
    if (error)
        return error;

    for (;;) {
        error = vfs_lock_file(filp, cmd, fl, NULL);
        if (error != FILE_LOCK_DEFERRED)
            break;
        error = wait_event_interruptible(fl->fl_wait, !fl->fl_next);
        if (!error)
            continue;

        locks_delete_block(fl);
        break;
    }

    return error;
}

~~~

如上代码段所示，"do_lock_file_wait()"的核心逻辑在"vfs_lock_file()"中，在这里将真正实现对文件资源的锁操作。

~~~

/* linux-3.10.103/linux-3.10.103/fs/locks.c */

/**
 * vfs_lock_file - file byte range lock
 * @filp: The file to apply the lock to
 * @cmd: type of locking operation (F_SETLK, F_GETLK, etc.)
 * @fl: The lock to be applied
 * @conf: Place to return a copy of the conflicting lock, if found.
 *
 * A caller that doesn't care about the conflicting lock may pass NULL
 * as the final argument.
 *
 * If the filesystem defines a private ->lock() method, then @conf will
 * be left unchanged; so a caller that cares should initialize it to
 * some acceptable default.
 *
 * To avoid blocking kernel daemons, such as lockd, that need to acquire POSIX
 * locks, the ->lock() interface may return asynchronously, before the lock has
 * been granted or denied by the underlying filesystem, if (and only if)
 * lm_grant is set. Callers expecting ->lock() to return asynchronously
 * will only use F_SETLK, not F_SETLKW; they will set FL_SLEEP if (and only if)
 * the request is for a blocking lock. When ->lock() does return asynchronously,
 * it must return FILE_LOCK_DEFERRED, and call ->lm_grant() when the lock
 * request completes.
 * If the request is for non-blocking lock the file system should return
 * FILE_LOCK_DEFERRED then try to get the lock and call the callback routine
 * with the result. If the request timed out the callback routine will return a
 * nonzero return code and the file system should release the lock. The file
 * system is also responsible to keep a corresponding posix lock when it
 * grants a lock so the VFS can find out which locks are locally held and do
 * the correct lock cleanup when required.
 * The underlying filesystem must not drop the kernel lock or call
 * ->lm_grant() before returning to the caller with a FILE_LOCK_DEFERRED
 * return code.
 */
int vfs_lock_file(struct file *filp, unsigned int cmd, struct file_lock *fl, struct file_lock *conf)
{
    if (filp->f_op && filp->f_op->lock)
        return filp->f_op->lock(filp, cmd, fl);
    else
        return posix_lock_file(filp, fl, conf);
}

~~~

"vfs_lock_file()"的源码注释很清晰地描述了记录锁对于"file->f_op->lock"的判断，和flock相似的，在Ext4中，其调用栈最终到了"posix_lock_file()"。

"posix_lock_file()"的逻辑和"flock"的"flock_lock_file()"基本上也是相似的，都是在"inode->i_flock"这个链表上增删改查，但是比"flock"复杂的地方在于fcntl需要考虑记录锁区间的交叉等问题。

最后，还是以一段fcntl的测试代码结尾。

~~~

/* fcntl.c */

#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <wait.h>

#define PATH "/tmp/lock"

int main(int argc, char *argv[])
{
    int fd;
    pid_t pid;

    fd = open(PATH, O_RDWR|O_CREAT|O_TRUNC, 0644);
    if (fd < 0) {
        perror("open()");
        exit(1);
    }

    if (write(fd, "fcntl", strlen("fcntl")) != strlen("fcntl")) {
        perror("write()");
        exit(1);
    }

    struct flock lock;
    lock.l_type = F_WRLCK;
    lock.l_whence = SEEK_SET;
    lock.l_start = 0;
    lock.l_len = strlen("fcntl");

    if (fcntl(fd, F_SETLK, &lock) < 0) {
        perror("fcntl()");
        exit(1);
    }
    printf("%d: locked!\n", getpid());

    pid = fork();
    if (pid < 0) {
        perror("fork()");
        exit(1);
    }

    if (pid == 0) {

        fd = open(PATH, O_RDWR|O_CREAT|O_TRUNC, 0644);
        if (fd < 0) {
            perror("open()");
            exit(1);
        }

        lock.l_start = strlen("fcntl");
        lock.l_len = 0;

        if (fcntl(fd, F_SETLK, &lock) < 0) {
            perror("fcntl()");
            exit(1);
        }
        printf("%d: locked!\n", getpid());
        exit(0);
    }
    wait(NULL);
    unlink(PATH);
    exit(0);

}

# gcc fcntl.c -o fcntl

# ./fcntl
11919: locked!
11920: locked!

~~~

可以看到，fcntl的F_WRLCK（排他锁）支持多个进程对同一个文件的不同区间同时加锁。

也可以把F_WRLCK（排他锁）改成F_RDLCK（共享锁），也可以针对文件的交叉区间进行加锁，还可以针对整个文件进行加锁，观察fcntl和flock的区别。

# 总结

在分析Linux内核文件锁的时候，有如下概念：

- 文件锁：针对整个文件的锁，如flock；

- 记录锁：针对整个文件和文件部分字节的锁，如fcntl、lockf；

- 排他锁：也可称为写锁、独占锁，同一时间只有一个进程可以加锁；

- 共享锁：也可称为读锁，支持多个进程并发读文件内容，但不可写；

- 睡眠锁：睡眠锁一般和等待队列同时存在，当无法获取锁时会在等待队列中睡眠，直到满足条件被唤醒，如semaphore、mutex；

- 自旋锁：自旋锁在被持有时，其它进程再申请时将不断"自旋"，不会陷入睡眠，直到持有者释放。为保证性能，自旋锁不应被持有时间过长。

- 建议锁：不要求进程一定要遵守，是一种约定俗成的规则，某进程持有建议锁的时候，其它进程依然可以强制操作，如flock、fcntl；

- 强制锁：[强制锁](https://www.kernel.org/doc/Documentation/filesystems/mandatory-locking.txt)是内核行为，在系统调用违反约束条件时，内核将直接阻拦，如fcntl（fcntl也可实现强制锁，但不建议使用）。


{% include references.md %}