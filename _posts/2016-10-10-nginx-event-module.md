---
layout: post
title: NGINX源码分析：事件模型
category: tech
---

# 前言

"nginx [engine x] is an HTTP and reverse proxy server, a mail proxy server, and a generic TCP/UDP proxy server"，这是NGINX官方对其的定义。

很显然的，NGINX更多地扮演着C/S模型中的Server角色，而TCP/IP协议栈中的服务端框架，主要包含两个基础结构：

- 端口侦听循环；

- 数据收发循环；

前者负责服务端的Socket连接服务，后者负责服务端的数据收发服务，服务端收到来自用户的请求数据，经过特定的应用逻辑，最终将生成的响应数据发送回用户端。

NGINX服务端的基础结构，也就是我们所熟知的事件模型，正是为其提供高效端口侦听和数据收发特性而存在的。

事件模型相关的一系列核心概念：

- 异步/同步

- 阻塞/非阻塞

在此不展开讨论，有兴趣的可以自己去探查select/poll/epoll/kqueue...的原理，本文分析的是NGINX事件模型的实现流程。

# NGINX的端口侦听

我们从NGINX源码的main函数开始来分析其端口侦听流程：

~~~

/* 本文的NGINX源码版本为[branch stable-1.10](https://github.com/nginx/nginx/tree/branches/stable-1.10) */

/* nginx/src/core/nginx.c */

int ngx_cdecl
main(int argc, char *const *argv)
{
    ...

    /* NGINX平滑升级时继承侦听的listen fd */
    if (ngx_add_inherited_sockets(&init_cycle) != NGX_OK) {
        return 1;
    }

    ...

    /* ngx_cycle初始化 */
    cycle = ngx_init_cycle(&init_cycle);
    if (cycle == NULL) {
        if (ngx_test_config) {
            ngx_log_stderr(0, "configuration file %s test failed",
                           init_cycle.conf_file.data);
        }

        return 1;
    }

    ...
}

~~~

可以看到，NGINX主函数对于端口侦听相关的函数为"ngx_add_inherited_sockets()"。这个函数有点复杂，不过它的主要作用是NGINX平滑升级（USR2）时用来继承老的master进程侦听的"listen fd"，有兴趣的可以直接参考文章[nginx多进程模型之热代码平滑升级](http://blog.csdn.net/brainkick/article/details/7192144)，本文还是来关注核心的初始化流程吧。

"ngx_init_cycle()"是NGINX启动流程中的核心函数，NGINX源码中的核心变量"volatile ngx_cycle_t  *ngx_cycle;"就是在该函数中完成初始化的。

~~~

/* nginx/src/core/nginx_core.h */

struct ngx_cycle_s {
    void                  ****conf_ctx;
    ngx_pool_t               *pool;

    ngx_log_t                *log;
    ngx_log_t                 new_log;

    ngx_uint_t                log_use_stderr;  /* unsigned  log_use_stderr:1; */

    ngx_connection_t        **files;
    ngx_connection_t         *free_connections; /* 空闲连接池 */
    ngx_uint_t                free_connection_n; /* 空闲连接池中连接的数量 */

    ngx_module_t            **modules;
    ngx_uint_t                modules_n;
    ngx_uint_t                modules_used;    /* unsigned  modules_used:1; */

    ngx_queue_t               reusable_connections_queue;

    ngx_array_t               listening; /* 侦听结构数组 */
    ngx_array_t               paths;
    ngx_array_t               config_dump;
    ngx_list_t                open_files;
    ngx_list_t                shared_memory;

    ngx_uint_t                connection_n; /* NGINX的连接总量 */
    ngx_uint_t                files_n;

    ngx_connection_t         *connections; /* NGINX的连接池 */
    ngx_event_t              *read_events;
    ngx_event_t              *write_events;

    ngx_cycle_t              *old_cycle;

    ngx_str_t                 conf_file;
    ngx_str_t                 conf_param;
    ngx_str_t                 conf_prefix;
    ngx_str_t                 prefix;
    ngx_str_t                 lock_file;
    ngx_str_t                 hostname;
};

~~~

我们可以从"ngx_cycle"的结构体声明"ngx_cycle_s"中看到，NGINX事件模型相关的核心内容 - 侦听结构的"listening"以及相关的"connections/free_connections"均在此处。

那么，我们继续从"ngx_init_cycle()"分析其源码实现。

~~~

/* nginx/src/core/nginx_cycle.c */

ngx_cycle_t *
ngx_init_cycle(ngx_cycle_t *old_cycle)
{
    ...

    /* 创建和初始化侦听结构数组 */
    n = old_cycle->listening.nelts ? old_cycle->listening.nelts : 10;

    cycle->listening.elts = ngx_pcalloc(pool, n * sizeof(ngx_listening_t));
    if (cycle->listening.elts == NULL) {
        ngx_destroy_pool(pool);
        return NULL;
    }

    /* 此时cycle->listening中的元素个数为0 */
    cycle->listening.nelts = 0;
    cycle->listening.size = sizeof(ngx_listening_t);
    cycle->listening.nalloc = n;
    cycle->listening.pool = pool;


    ngx_queue_init(&cycle->reusable_connections_queue);

    ...

    /* NGINX的配置解析流程 */
    if (ngx_conf_parse(&conf, &cycle->conf_file) != NGX_CONF_OK) {
        environ = senv;
        ngx_destroy_cycle_pools(&conf);
        return NULL;
    }

    ...

    /* handle the listening sockets */

    if (old_cycle->listening.nelts) {

    	...

    } else {
        ls = cycle->listening.elts;
        for (i = 0; i < cycle->listening.nelts; i++) {
            ls[i].open = 1;
#if (NGX_HAVE_DEFERRED_ACCEPT && defined SO_ACCEPTFILTER)
            if (ls[i].accept_filter) {
                ls[i].add_deferred = 1;
            }
#endif
#if (NGX_HAVE_DEFERRED_ACCEPT && defined TCP_DEFER_ACCEPT)
            if (ls[i].deferred_accept) {
                ls[i].add_deferred = 1;
            }
#endif
        }
    }

    /* 在此处才真正创建NGINX的侦听套接字 */
    if (ngx_open_listening_sockets(cycle) != NGX_OK) {
        goto failed;
    }

    if (!ngx_test_config) {
        ngx_configure_listening_sockets(cycle);
    }

    ...
}

~~~

NGINX在"ngx_init_cycle()"中首先为侦听结构的"listening"数组完成初始化操作，其元素个数"n"在正常启动流程时为10。

我们暂时忽略上面代码段的中间部分"ngx_conf_parse()"，这部分内容是NGINX解析配置文件，从配置文件中读出侦听地址、侦听端口的逻辑，稍后再讲。

注释部分"handle the listening sockets"相关的代码设置了"listening"中的部分字段。

"ngx_open_listening_sockets()"和"ngx_configure_listening_sockets()"是真正的建立Socket的源码实现：

~~~

/* nginx/src/core/ngx_connections.c */

ngx_int_t
ngx_open_listening_sockets(ngx_cycle_t *cycle)
{
    ...

    /* 系统调用socket() => bind() => listen()完成套接字的建立 */

    /* for each listening socket */

    ls = cycle->listening.elts;
    for (i = 0; i < cycle->listening.nelts; i++) {

    	...

    	s = ngx_socket(ls[i].sockaddr->sa_family, ls[i].type, 0);

        if (s == (ngx_socket_t) -1) {
            ngx_log_error(NGX_LOG_EMERG, log, ngx_socket_errno,
                          ngx_socket_n " %V failed", &ls[i].addr_text);
            return NGX_ERROR;
        }

        if (setsockopt(s, SOL_SOCKET, SO_REUSEADDR,
                       (const void *) &reuseaddr, sizeof(int))
            == -1)
        {
            ngx_log_error(NGX_LOG_EMERG, log, ngx_socket_errno,
                          "setsockopt(SO_REUSEADDR) %V failed",
                          &ls[i].addr_text);

            if (ngx_close_socket(s) == -1) {
                ngx_log_error(NGX_LOG_EMERG, log, ngx_socket_errno,
                              ngx_close_socket_n " %V failed",
                              &ls[i].addr_text);
            }

            return NGX_ERROR;
        }

        ...

        if (bind(s, ls[i].sockaddr, ls[i].socklen) == -1) {
            err = ngx_socket_errno;

            if (err != NGX_EADDRINUSE || !ngx_test_config) {
                ngx_log_error(NGX_LOG_EMERG, log, err,
                              "bind() to %V failed", &ls[i].addr_text);
            }

            if (ngx_close_socket(s) == -1) {
                ngx_log_error(NGX_LOG_EMERG, log, ngx_socket_errno,
                              ngx_close_socket_n " %V failed",
                              &ls[i].addr_text);
            }

            if (err != NGX_EADDRINUSE) {
                return NGX_ERROR;
            }

            if (!ngx_test_config) {
                failed = 1;
            }

            continue;
        }

        ...

        if (listen(s, ls[i].backlog) == -1) {
            err = ngx_socket_errno;

            /*
             * on OpenVZ after suspend/resume EADDRINUSE
             * may be returned by listen() instead of bind(), see
             * https://bugzilla.openvz.org/show_bug.cgi?id=2470
             */

            if (err != NGX_EADDRINUSE || !ngx_test_config) {
                ngx_log_error(NGX_LOG_EMERG, log, err,
                              "listen() to %V, backlog %d failed",
                              &ls[i].addr_text, ls[i].backlog);
            }

            if (ngx_close_socket(s) == -1) {
                ngx_log_error(NGX_LOG_EMERG, log, ngx_socket_errno,
                              ngx_close_socket_n " %V failed",
                              &ls[i].addr_text);
            }

            if (err != NGX_EADDRINUSE) {
                return NGX_ERROR;
            }

            if (!ngx_test_config) {
                failed = 1;
            }

                continue;
        }

        ...

    }

    ...

    return NGX_OK;
}

void
ngx_configure_listening_sockets(ngx_cycle_t *cycle)
{
    ...

    /* 系统调用setsockopt()完成套接字的配置 */

    ls = cycle->listening.elts;
    for (i = 0; i < cycle->listening.nelts; i++) {

        ls[i].log = *ls[i].logp;

        if (ls[i].rcvbuf != -1) {
            if (setsockopt(ls[i].fd, SOL_SOCKET, SO_RCVBUF,
                           (const void *) &ls[i].rcvbuf, sizeof(int))
                == -1)
            {
                ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_socket_errno,
                              "setsockopt(SO_RCVBUF, %d) %V failed, ignored",
                              ls[i].rcvbuf, &ls[i].addr_text);
            }
        }

        if (ls[i].sndbuf != -1) {
            if (setsockopt(ls[i].fd, SOL_SOCKET, SO_SNDBUF,
                           (const void *) &ls[i].sndbuf, sizeof(int))
                == -1)
            {
                ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_socket_errno,
                              "setsockopt(SO_SNDBUF, %d) %V failed, ignored",
                              ls[i].sndbuf, &ls[i].addr_text);
            }
        }

        if (ls[i].keepalive) {
            value = (ls[i].keepalive == 1) ? 1 : 0;

            if (setsockopt(ls[i].fd, SOL_SOCKET, SO_KEEPALIVE,
                           (const void *) &value, sizeof(int))
                == -1)
            {
                ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_socket_errno,
                              "setsockopt(SO_KEEPALIVE, %d) %V failed, ignored",
                              value, &ls[i].addr_text);
            }
        }

        ...
    }
    ...
}

~~~

可以看到，在该部分源码中，NGINX将遍历"cycle->listening"数组，逐个调用"socket()", "bind()"和"listen()"完成侦听操作，同时，调用"setsockopt()"函数设置socket选项，比如接收缓冲区、发送缓冲区等。

所以，"ngx_open_listening_sockets()"和"ngx_configure_listening_sockets()"是NGINX侦听结构初始化的流程末尾，在这里，完成了NGINX服务所有套接字Socket的建立和配置，只需要静待新连接的到来，也就是等待"accept()"的循环调用。

那么，我们还缺少了一环，就是每个Socket的地址信息是从何处获取的呢？

我们来分析上文提到的"ngx_conf_parse()"，忽略配置解析的细节，只关注侦听相关部分。

NGINX配置文件中的HTTP BLOCK和SERVER BLOCK定义了HTTP相关的虚拟主机的配置项，在SERVER BLOCK中，配置项"listen"和"server_name"指明了NGINX作为服务端所监听的端口和域名地址。

OK，那么在解析HTTP BLOCK和SERVER BLOCK时NGINX做了些什么呢，我们来分析HTTP模块的核心函数"ngx_http_block()"。

~~~

/* nginx/src/http/ngx_http.c */

static char *
ngx_http_block(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ...

    /* 建立Server信息的哈希表，用于多虚拟主机的分发 */

    /* optimize the lists of ports, addresses and server names */

    if (ngx_http_optimize_servers(cf, cmcf, cmcf->ports) != NGX_OK) {
        return NGX_CONF_ERROR;
    }

    ...
}

~~~

具体的配置项解析流程请自行检索，我们默认分析到此处，配置项"listen"和"server_name"相关的端口和域名地址已经被解析和存储于"cmcf->ports"中。

于是，我们拿着已经解析完的域名和端口"cmcf->ports"作为入参，调用"ngx_http_optimize_servers()"。

~~~

/* nginx/src/http/ngx_http.c */

static ngx_int_t
ngx_http_optimize_servers(ngx_conf_t *cf, ngx_http_core_main_conf_t *cmcf,
    ngx_array_t *ports)
{
    ngx_uint_t             p, a;
    ngx_http_conf_port_t  *port;
    ngx_http_conf_addr_t  *addr;

    if (ports == NULL) {
        return NGX_OK;
    }

    port = ports->elts;
    for (p = 0; p < ports->nelts; p++) {

        /* 地址排序 */

        ngx_sort(port[p].addrs.elts, (size_t) port[p].addrs.nelts,
                 sizeof(ngx_http_conf_addr_t), ngx_http_cmp_conf_addrs);

        /*
         * check whether all name-based servers have the same
         * configuration as a default server for given address:port
         */

        addr = port[p].addrs.elts;
        for (a = 0; a < port[p].addrs.nelts; a++) {

            if (addr[a].servers.nelts > 1
#if (NGX_PCRE)
                || addr[a].default_server->captures
#endif
               )
            {
            	/* 建立哈希表 */
                if (ngx_http_server_names(cf, cmcf, &addr[a]) != NGX_OK) {
                    return NGX_ERROR;
                }
            }
        }

        /* 将地址信息添加到cycle->listening中，同时设置回调函数 */
        if (ngx_http_init_listening(cf, &port[p]) != NGX_OK) {
            return NGX_ERROR;
        }
    }

    return NGX_OK;
}

~~~

"ngx_http_optimize_servers()"的核心工作有三点：

- 将侦听的域名地址addr排序，带通配符的地址排在后面；

- 初始化侦听域名地址addr中的哈希表，当请求来时，根据HOST信息分发请求至对应的虚拟主机；

- 初始化listening信息，"ngx_http_init_listening()" => "ngx_http_add_listening()"；

~~~

/* nginx/src/http/ngx_http.c */

static ngx_int_t
ngx_http_init_listening(ngx_conf_t *cf, ngx_http_conf_port_t *port)
{
    ...

    addr = port->addrs.elts;
    last = port->addrs.nelts;

    ...

    /* 填充cycle->listening中的元素，实际个数与port列表相关 */

    while (i < last) {

        ...

        ls = ngx_http_add_listening(cf, &addr[i]);

        ...

        addr++;
        last--;
    }

    ...
}

static ngx_listening_t *
ngx_http_add_listening(ngx_conf_t *cf, ngx_http_conf_addr_t *addr)
{
    ...

    /* 创建"ngx_listening_t"结构体实例 */
    ls = ngx_create_listening(cf, &addr->opt.u.sockaddr, addr->opt.socklen);
    if (ls == NULL) {
        return NULL;
    }

    ls->addr_ntop = 1;

    /* 为cycle->listening中的每个元素设置回调函数 */
    ls->handler = ngx_http_init_connection;

    ...
}

~~~


如上，"ngx_http_add_listening()"将"listening"的回调函数设置为"ngx_http_init_connection()"。

此时，端口已经处于侦听状态，NGINX只需要等待用户请求的来临，事件模型将继续负责高效地驱动数据的收发循环。

通过源码分析可知，NGINX的端口侦听主要包含如下步骤：

- 初始化cycle->listening数组，该结构将保存NGINX的侦听地址和端口信息；

- 解析配置文件，分组填充cycle->listening；

- 建立和配置cycle->listening对应的所有套接字Socket，完成"socket()", "listen()"和"bind()"操作；

- 建立与事件模型的关联关系，等待事件驱动"accept()"循环；


*NGINX其实是支持多HTTP BLOCK的配置的，经过测试，多HTTP BLOCK的侦听循环都是正常运行的，它的实现原理其实也蕴含在上面的源码分析中，有兴趣的可以自己思考一下*


# NGINX的事件模型

NGINX的端口侦听源码，最后将侦听结构的回调函数设置为"ngx_http_init_connection()"，它是NGINX数据收发循环的入口，和事件模型有紧密的关系。

那么，我们将继续分析NGINX事件模型是如何驱动"accept()"循环，以及如何调用"ngx_http_init_connection()"进入数据收发循环。

上文提到过，"ngx_cycle"中除了"listening"成员外，还存在关联的"connections/free_connections"，它们是NGINX中的"连接"，每个连接均对应着TCP/IP协议中的一次"accept()"，也对应着事件模型中的一个读事件和写事件。而读写事件也是"ngx_cycle"的成员，对应的字段为"read_events"和"write_events"。

那么，"ngx_cycle"的这几个成员 - "listening"、"connections/free_connections"和"read_events/write_events"是如何关联起来的呢，我们继续通过源码分析其实现。

NGINX的main函数在启动流程的末尾阶段，将逐个调用每个模块的"init process"回调函数，在NGINX的事件模块"ngx_event_core_module"源码中，"init process"回调函数被设置为"ngx_event_process_init()"，我们来分析其实现源码。

~~~

/* nginx/src/event/ngx_event.c */

static ngx_int_t
ngx_event_process_init(ngx_cycle_t *cycle)
{
    ...

    for (m = 0; cycle->modules[m]; m++) {
        if (cycle->modules[m]->type != NGX_EVENT_MODULE) {
            continue;
        }

        if (cycle->modules[m]->ctx_index != ecf->use) {
            continue;
        }

        module = cycle->modules[m]->ctx;

        /* 调用NGX_EVENT_MODULE模块的事件初始化函数 */

        if (module->actions.init(cycle, ngx_timer_resolution) != NGX_OK) {
            /* fatal */
            exit(2);
        }

        break;
    }

    ...
}

~~~

"ngx_event_process_init()"的核心代码很多，我们逐段分析。

可以看到，如上代码段将循环遍历类型为NGX_EVENT_MODULE的模块。

"ngx_select_module"、"ngx_poll_module"、"ngx_epoll_module"、"ngx_kqueue_module"等等，都是NGX_EVENT_MODULE类型的模块。

在不同的平台上，select/poll/epoll/kqueue只有一种会生效，本文只讨论epoll。

也就是说，"ngx_event_process_init()"在循环遍历后，"ngx_epoll_module"的"actions.init"函数将被调用。

"ngx_epoll_module"的"actions.init"在模块定义时被设置为"ngx_epoll_init()"。

~~~

/* nginx/src/event/modules/ngx_epoll_module.c */

static ngx_int_t
ngx_epoll_init(ngx_cycle_t *cycle, ngx_msec_t timer)
{
    ...

    /* 创建epoll对象 */

    ep = epoll_create(cycle->connection_n / 2);

    if (ep == -1) {
        ngx_log_error(NGX_LOG_EMERG, cycle->log, ngx_errno,
                      "epoll_create() failed");
        return NGX_ERROR;
    }

    ...
}

~~~

有空再分析epoll的源码实现，这里，我们只关心epoll的系统调用"epoll_create()"、"epoll_ctl()"和"epoll_wait()"：

- "epoll_create()": 创建一个epoll对象；

- "epoll_ctl()"：注册epoll事件；

- "epoll_wait()"：等待事件被唤醒；

所以，"ngx_epoll_init()"创建了一个epoll对象，它的参数"cycle->connection_n / 2"暂时也没什么意义，因为现版本的epoll实现其实也没用上该参数。

我们继续分析"ngx_event_process_init()"的实现：

~~~

/* nginx/src/event/modules/ngx_epoll_module.c */

static ngx_int_t
ngx_epoll_init(ngx_cycle_t *cycle, ngx_msec_t timer)

{
    ...

    /* 创建连接池、读事件、写事件 */

    cycle->connections =
        ngx_alloc(sizeof(ngx_connection_t) * cycle->connection_n, cycle->log);
    if (cycle->connections == NULL) {
        return NGX_ERROR;
    }

    c = cycle->connections;

    cycle->read_events = ngx_alloc(sizeof(ngx_event_t) * cycle->connection_n,
                                   cycle->log);
    if (cycle->read_events == NULL) {
        return NGX_ERROR;
    }

    rev = cycle->read_events;
    for (i = 0; i < cycle->connection_n; i++) {
        rev[i].closed = 1;
        rev[i].instance = 1;
    }

    cycle->write_events = ngx_alloc(sizeof(ngx_event_t) * cycle->connection_n,
                                    cycle->log);
    if (cycle->write_events == NULL) {
        return NGX_ERROR;
    }

    wev = cycle->write_events;
    for (i = 0; i < cycle->connection_n; i++) {
        wev[i].closed = 1;
    }

    i = cycle->connection_n;
    next = NULL;

    /* 每个连接都实际对应一个读写事件，连接池的本质是链表 */

    do {
        i--;

        c[i].data = next;
        c[i].read = &cycle->read_events[i];
        c[i].write = &cycle->write_events[i];
        c[i].fd = (ngx_socket_t) -1;

        next = &c[i];
    } while (i);

    cycle->free_connections = next;
    cycle->free_connection_n = cycle->connection_n;

    /* 遍历cycle->listening，为每一个侦听结构分配一个空闲连接，所以，实际用来等待accpet()的连接其实就那么几个，剩下的都用来收发循环，后面还会提到 */

    /* for each listening socket */

    ls = cycle->listening.elts;
    for (i = 0; i < cycle->listening.nelts; i++) {

#if (NGX_HAVE_REUSEPORT)
        if (ls[i].reuseport && ls[i].worker != ngx_worker) {
            continue;
        }
#endif

        c = ngx_get_connection(ls[i].fd, cycle->log);

        if (c == NULL) {
            return NGX_ERROR;
        }

        c->type = ls[i].type;
        c->log = &ls[i].log;

        c->listening = &ls[i];
        ls[i].connection = c;

        rev = c->read;

        rev->log = c->log;
        rev->accept = 1;

#if (NGX_HAVE_DEFERRED_ACCEPT)
        rev->deferred_accept = ls[i].deferred_accept;
#endif

        if (!(ngx_event_flags & NGX_USE_IOCP_EVENT)) {
            if (ls[i].previous) {

                /*
                 * delete the old accept events that were bound to
                 * the old cycle read events array
                 */

                old = ls[i].previous->connection;

                if (ngx_del_event(old->read, NGX_READ_EVENT, NGX_CLOSE_EVENT)
                    == NGX_ERROR)
                {
                    return NGX_ERROR;
                }

                old->fd = (ngx_socket_t) -1;
            }
        }

        ...

        /* 设置读事件的回调为ngx_event_accept */

        rev->handler = (c->type == SOCK_STREAM) ? ngx_event_accept
                                                : ngx_event_recvmsg;

        if (ngx_use_accept_mutex
#if (NGX_HAVE_REUSEPORT)
            && !ls[i].reuseport
#endif
           )
        {
            continue;
        }

        if (ngx_add_event(rev, NGX_READ_EVENT, 0) == NGX_ERROR) {
            return NGX_ERROR;
        }

#endif

    }
    ...
}

~~~

这段代码很清晰地将"listening"、"connections"和"read_events/write_events"关联起来。

首先，NGINX创建了"connection_n"个连接，"connection_n"可以利用配置文件的"worker_connections"参数来配置，默认为1024。

其次，NGINX创建了"connection_n"个读写事件，在do循环里将读写事件添加为"ngx_connection_t"的成员，同时，利用"data"字段将所有的连接链接成一个链表，cycle->free_connections指向第一个空闲的连接。这种双链表的小对象内存池方案很常见，Linux内核和CPython的实现都在大量使用。

再次，NGINX将遍历数组"cycle->listening"，并取出对应个数的空闲连接，将侦听套接字关联到这些连接中。这样，NGINX的事件模型终于将套接字、连接和事件全部关联在一个结构中。

最后，NGINX调用"ngx_add_event()" => "ngx_event_actions.add" => "ngx_epoll_add_event()" => "epoll_ctl()"将读事件添加到epoll中，并且设置读事件的回调函数为"ngx_event_accept()"。

至此，NGINX的事件模型已经完成了整体的初始化流程，后续只需要等待epoll唤醒读事件来接收来自客户端的连接请求，我们将在"NGINX的事件驱动"中继续分析请求/响应流程。

# NGINX的事件驱动循环

已经分析完毕NGINX的端口侦听和事件模型的初始化流程，现在我们继续分析NGINX的事件是如何驱动侦听循环和收发循环的。

NGINX的worker进程在启动完毕后，核心流程就是一个for循环，如下源码所示：

~~~

/* nginx/src/os/unix/ngx_process_cycle.c */

static void
ngx_worker_process_cycle(ngx_cycle_t *cycle, void *data)
{
    ngx_int_t worker = (intptr_t) data;

    ngx_process = NGX_PROCESS_WORKER;
    ngx_worker = worker;

    ngx_worker_process_init(cycle, worker);

    ngx_setproctitle("worker process");

    /* ngx_exiting、ngx_terminate、ngx_quit、ngx_reopen，均为启停信号 */

    for ( ;; ) {

        if (ngx_exiting) {
            ngx_event_cancel_timers();

            if (ngx_event_timer_rbtree.root == ngx_event_timer_rbtree.sentinel)
            {
                ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "exiting");

                ngx_worker_process_exit(cycle);
            }
        }

        ngx_log_debug0(NGX_LOG_DEBUG_EVENT, cycle->log, 0, "worker cycle");

        /* work进程的工作循环核心函数 */

        ngx_process_events_and_timers(cycle);

        if (ngx_terminate) {
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "exiting");

            ngx_worker_process_exit(cycle);
        }

        if (ngx_quit) {
            ngx_quit = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0,
                          "gracefully shutting down");
            ngx_setproctitle("worker process is shutting down");

            if (!ngx_exiting) {
                ngx_exiting = 1;
                ngx_close_listening_sockets(cycle);
                ngx_close_idle_connections(cycle);
            }
        }

        if (ngx_reopen) {
            ngx_reopen = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "reopening logs");
            ngx_reopen_files(cycle, -1);
        }
    }
}

~~~

可以看到，worker进程的核心工作内容除了等待启停信号，只剩下"ngx_process_events_and_timers()"函数，它就是我们关注的事件驱动循环。

我们继续分析：

~~~

/* nginx/src/event/ngx_event.c */

void
ngx_process_events_and_timers(ngx_cycle_t *cycle)
{
    ...

    /* NGINX的惊群问题 */

    if (ngx_use_accept_mutex) {
        if (ngx_accept_disabled > 0) {
            ngx_accept_disabled--;

        } else {
            if (ngx_trylock_accept_mutex(cycle) == NGX_ERROR) {
                return;
            }

            if (ngx_accept_mutex_held) {
                flags |= NGX_POST_EVENTS;

            } else {
                if (timer == NGX_TIMER_INFINITE
                    || timer > ngx_accept_mutex_delay)
                {
                    timer = ngx_accept_mutex_delay;
                }
            }
        }
    }

    delta = ngx_current_msec;

    /* 调用epoll等事件模块的事件处理函数 */

    (void) ngx_process_events(cycle, timer, flags);

    delta = ngx_current_msec - delta;

    ngx_log_debug1(NGX_LOG_DEBUG_EVENT, cycle->log, 0,
                   "timer delta: %M", delta);

    /* accept队列仍有唤醒的事件，继续接收 */

    ngx_event_process_posted(cycle, &ngx_posted_accept_events);

    if (ngx_accept_mutex_held) {
        ngx_shmtx_unlock(&ngx_accept_mutex);
    }

    if (delta) {
        ngx_event_expire_timers();
    }

    /* 仍有延迟的其它事件，继续处理 */
    ngx_event_process_posted(cycle, &ngx_posted_events);
}

~~~

NGINX的惊群问题请参考下面的文章，本文不展开讨论：

- [“惊群”，看看nginx是怎么解决它的](http://blog.csdn.net/russell_tao/article/details/7204260)

- [accept与epoll惊群](https://rocfang.gitbooks.io/dev-notes/content/acceptyu_epoll_liang_qun.html)

"ngx_process_events()"是NGINX worker进程的核心工作，它负责驱动侦听结构相关的事件循环，是侦听循环的入口。

我们从源码定位它的真正调用位置：

~~~

/* nginx/src/event/ngx_event.h */

#define ngx_process_events   ngx_event_actions.process_events

/* nginx/src/modules/ngx_epoll_module.c */

static ngx_int_t
ngx_epoll_init(ngx_cycle_t *cycle, ngx_msec_t timer)
{
    ...

    ngx_event_actions = ngx_epoll_module_ctx.actions;

    ...
}

~~~

"ngx_process_events()"在NGINX中被定义为"ngx_epoll_module_ctx.actions"，和上文的"actions.init"相似的，我们可以定位到"ngx_epoll_process_events()"函数：

~~~

/* nginx/src/modules/ngx_epoll_module.c */

static ngx_int_t
ngx_epoll_process_events(ngx_cycle_t *cycle, ngx_msec_t timer, ngx_uint_t flags)
{
    ...

    /* epoll_wait返回唤醒事件个数，event_list保存唤醒的事件 */

    events = epoll_wait(ep, event_list, (int) nevents, timer);

    ...

    for (i = 0; i < events; i++) {
        c = event_list[i].data.ptr;

        instance = (uintptr_t) c & 1;
        c = (ngx_connection_t *) ((uintptr_t) c & (uintptr_t) ~1);

        /* 取得唤醒事件对应的连接和读写事件 */

        rev = c->read;

        ...

        if ((revents & EPOLLIN) && rev->active) {

#if (NGX_HAVE_EPOLLRDHUP)
            if (revents & EPOLLRDHUP) {
                rev->pending_eof = 1;
            }
#endif

            rev->ready = 1;

            if (flags & NGX_POST_EVENTS) {
                queue = rev->accept ? &ngx_posted_accept_events
                                    : &ngx_posted_events;

                ngx_post_event(rev, queue);

            } else {

                /* 读事件的handler为ngx_event_accept() */
                rev->handler(rev);
            }
        }

        ...

        wev = c->write;

        if ((revents & EPOLLOUT) && wev->active) {

            if (c->fd == -1 || wev->instance != instance) {

                /*
                 * the stale event from a file descriptor
                 * that was just closed in this iteration
                 */

                ngx_log_debug1(NGX_LOG_DEBUG_EVENT, cycle->log, 0,
                               "epoll: stale event %p", c);
                continue;
            }

            wev->ready = 1;
#if (NGX_THREADS)
            wev->complete = 1;
#endif

            if (flags & NGX_POST_EVENTS) {
                ngx_post_event(wev, &ngx_posted_events);

            } else {

            	/* 如果可写，则回调写事件的handler */
                wev->handler(wev);
            }
        }

        ...

    }

    return NGX_OK;
}

~~~


NGINX的事件驱动机制循环遍历epoll中的唤醒事件，如果有新的连接到来，则epoll_wait将返回唤醒事件的列表，每一个事件关联的连接对象中均可以得到"read/write"指代的读写事件。

我们从上面的分析中已经知道，读事件的回调函数是"ngx_event_accept()"：

~~~

/* nginx/src/event/ngx_event_accept.c */

void
ngx_event_accept(ngx_event_t *ev)
{
    ...

    ngx_event_t       *rev, *wev;
    ngx_listening_t   *ls;

    ...

    /* NGINX的事件、连接和侦听结构互相关联 */

    lc = ev->data;
    ls = lc->listening;

    ... 

    /* 系统调用accept()接受新的连接 */

    do {
        socklen = NGX_SOCKADDRLEN;

#if (NGX_HAVE_ACCEPT4)
        if (use_accept4) {
            s = accept4(lc->fd, (struct sockaddr *) sa, &socklen,
                        SOCK_NONBLOCK);
        } else {
            s = accept(lc->fd, (struct sockaddr *) sa, &socklen);
        }
#else
        s = accept(lc->fd, (struct sockaddr *) sa, &socklen);
#endif

        ...

        /* NGINX的worker进程负载均衡策略 */
    
        ngx_accept_disabled = ngx_cycle->connection_n / 8
                                  - ngx_cycle->free_connection_n;
    
        /* 从连接池中取出一个空闲的连接来驱动数据循环，并不是直接使用入参ev关联的连接 */
    
        c = ngx_get_connection(s, ev->log);
    
        if (c == NULL) {
            if (ngx_close_socket(s) == -1) {
                ngx_log_error(NGX_LOG_ALERT, ev->log, ngx_socket_errno,
                              ngx_close_socket_n " failed");
            }
    
            return;
        }
    
        c->type = SOCK_STREAM;
    
#if (NGX_STAT_STUB)
        (void) ngx_atomic_fetch_add(ngx_stat_active, 1);
#endif

        c->pool = ngx_create_pool(ls->pool_size, ev->log);
        if (c->pool == NULL) {
            ngx_close_accepted_connection(c);
            return;
        }
    
        c->sockaddr = ngx_palloc(c->pool, socklen);
        if (c->sockaddr == NULL) {
            ngx_close_accepted_connection(c);
            return;
        }
    
        ngx_memcpy(c->sockaddr, sa, socklen);
    
        log = ngx_palloc(c->pool, sizeof(ngx_log_t));
        if (log == NULL) {
            ngx_close_accepted_connection(c);
            return;
        }

        ...

        *log = ls->log;
    
        c->recv = ngx_recv;
        c->send = ngx_send;
        c->recv_chain = ngx_recv_chain;
        c->send_chain = ngx_send_chain;
    
        c->log = log;
        c->pool->log = log;
    
        c->socklen = socklen;
        c->listening = ls;
        c->local_sockaddr = ls->sockaddr;
        c->local_socklen = ls->socklen;
    
        c->unexpected_eof = 1;

#if (NGX_HAVE_UNIX_DOMAIN)
        if (c->sockaddr->sa_family == AF_UNIX) {
            c->tcp_nopush = NGX_TCP_NOPUSH_DISABLED;
            c->tcp_nodelay = NGX_TCP_NODELAY_DISABLED;
#if (NGX_SOLARIS)
        /* Solaris's sendfilev() supports AF_NCA, AF_INET, and AF_INET6 */
        c->sendfile = 0;
#endif
        }
#endif

        rev = c->read;
        wev = c->write;
    
        wev->ready = 1;
    
        if (ngx_event_flags & NGX_USE_IOCP_EVENT) {
            rev->ready = 1;
        }
    
        if (ev->deferred_accept) {
            rev->ready = 1;
#if (NGX_HAVE_KQUEUE)
            rev->available = 1;
#endif
        }

            rev->log = log;
            wev->log = log;

        ...

        }

        ...

        /* 侦听结构的handler为ngx_http_init_connection() */

        ls->handler(c);

    } while (ev->available)
}

~~~

上面我们提过，NGINX的端口侦听已经完成了Socket的"socket()" => "bind()" => "listen()"，现在，我们终于等到了系统调用"accept()"，也就是说，此时，来自用户的连接经过TCP的三次握手后，已经可以在NGINX中以连接的方式存在。但是，这种连接是NGINX重新从空闲连接池中取到的，经过一系列填充后，我们终于又回到了最初的侦听结构的回调函数"ngx_http_init_connection()"。

~~~

/* nginx/src/http/ngx_http_request.c */

void
ngx_http_init_connection(ngx_connection_t *c)
{
    ...

    /* 将读事件的回调修改为ngx_http_wait_request_handler，如果是HTTP 2.0或者HTTPS，则修改为ngx_http_v2_init或者ngx_http_ssl_handshake */

    rev = c->read;
    rev->handler = ngx_http_wait_request_handler;
    c->write->handler = ngx_http_empty_handler;

#if (NGX_HTTP_V2)
    if (hc->addr_conf->http2) {
        rev->handler = ngx_http_v2_init;
    }
#endif

#if (NGX_HTTP_SSL)
    {
    ngx_http_ssl_srv_conf_t  *sscf;

    sscf = ngx_http_get_module_srv_conf(hc->conf_ctx, ngx_http_ssl_module);

    if (sscf->enable || hc->addr_conf->ssl) {

        c->log->action = "SSL handshaking";

        if (hc->addr_conf->ssl && sscf->ssl.ctx == NULL) {
            ngx_log_error(NGX_LOG_ERR, c->log, 0,
                          "no \"ssl_certificate\" is defined "
                          "in server listening on SSL port");
            ngx_http_close_connection(c);
            return;
        }

        hc->ssl = 1;

        rev->handler = ngx_http_ssl_handshake;
    }
    }
#endif

    ...

    if (rev->ready) {
        /* the deferred accept(), iocp */

        if (ngx_use_accept_mutex) {
            ngx_post_event(rev, &ngx_posted_events);
            return;
        }

        /* 此处将调用ngx_http_wait_request_handler、ngx_http_v2_init或者ngx_http_ssl_handshake */

        rev->handler(rev);
        return;
    }

    ngx_add_timer(rev, c->listening->post_accept_timeout);
    ngx_reusable_connection(c, 1);

    if (ngx_handle_read_event(rev, 0) != NGX_OK) {
        ngx_http_close_connection(c);
        return;
    }
}

~~~

此刻，我们可以清晰地认识到，从"ngx_http_init_connection()"函数开始，NGINX已经进入了真正的应用循环，NGINX作为HTTP SERVER，将调用"ngx_http_wait_request_handler"、"ngx_http_v2_init"或者"ngx_http_ssl_handshake"来处理HTTP、HTTP 2.0或者HTTPS请求。

依然阶段性总结一下：

- NGINX事件驱动的侦听入口：worker进程的工作循环在epoll中有事件被唤醒时将"accept()"接收新连接的到来；

- NGINX事件驱动的收发入口：在新连接到来后，NGINX将顺着读事件的回调收取缓存中请求数据，进入应用层循环；

我们在分析上述两个入口的过程中，其实也已经提到过相应的写事件，当响应生成时，NGINX将逆向处理，由相关的写事件完成发送操作。

NGINX在完成响应发送操作或者异常处理操作之后，会将使用过的连接释放回空闲连接池，重新回到worker进程的工作循环，继续侦听。

# 总结

NGINX的事件模型非常精妙，一环扣一环地完成侦听结构、连接池和事件的关联。

同时，通过事件模块的抽象，可以跨平台地使用select/poll/epoll/kqueue...来驱动事件。

而事件在NGINX worker进程的工作循环中又不断驱动着侦听循环和收发循环。

表示对NGINX的事件模型叹为观止，受益匪浅~~

{% include references.md %}
