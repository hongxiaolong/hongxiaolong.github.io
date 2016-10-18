---
layout: post
title: NGINX源码分析：错误页面
category: tech
---

NGINX源码中，错误内容对内表现为（宏定义）NGX_ERROR、NGX_BUSY以及HTTP协议相关的NGX_HTTP_INTERNAL_SERVER_ERROR、NGX_HTTP_GATEWAY_TIME_OUT等，对外则返回响应，HTTP协议的响应包含错误码如404、500、503和内容为text/html的错误页面，当错误页面重定向时还需要Header中的Location字段支持。

简单总结NGINX错误页面的配置项后再从源码详细分析其流程：

~~~

[error_page](http://nginx.org/en/docs/http/ngx_http_core_module.html#error_page)

语法：error_page code ... [=[response]] uri;
默认值：—
配置块：http, server, location, location中的if字段 

示例：

常见静态页方式错误页面配置如下：

error_page   404          /404.html;
error_page   502 503 504  /50x.html;

可以同时配置内部和外部错误，如：

error_page   403          http://example.com/forbidden.html;
error_page   404          = @fetch;

也可以将原有的响应代码替换为另一个响应代码，如：

error_page 404 =200 /empty.gif;
error_page 404 =403 /forbidden.gif;

还可以指定错误由PHP等其它程序返回：

error_page   404  =  /404.php;

如果在重定向时不想改变URI，可以通过命名location和反向代理最终生成响应：

location / (
    error_page 404 @fallback;
)

location @fallback (
    proxy_pass http://backend;
)

~~~


error_page可以位于http, server, location配置块中，其继承关系经过merge后最终汇总于ngx_http_core_loc_conf_s中的error_pages中。

~~~

struct ngx_http_core_loc_conf_s {
    ngx_str_t     name;          /* location name */
    ...

    ngx_array_t  *error_pages;             /* error_page */

    ...
}

~~~


综上，NGINX错误页面的配置和理解其实并不简单，但是总结起来也就这么几种情况：

- 内部错误页

- 外部错误页

- 未配置

化繁为简后，我们再从源码分析其流程，以NGINX限流模块返回503错误码为例：

~~~

static ngx_int_t
ngx_http_limit_req_handler(ngx_http_request_t *r)
{
    ...

    if (rc == NGX_BUSY || rc == NGX_ERROR) {

        if (rc == NGX_BUSY) {
            ngx_log_error(lrcf->limit_log_level, r->connection->log, 0,
                          "limiting requests, excess: %ui.%03ui by zone \"%V\"",
                          excess / 1000, excess % 1000,
                          &limit->shm_zone->shm.name);
        }

        while (n--) {
            ctx = limits[n].shm_zone->data;
    
            if (ctx->node == NULL) {
                continue;
            }

            ngx_shmtx_lock(&ctx->shpool->mutex);

            ctx->node->count--;

            ngx_shmtx_unlock(&ctx->shpool->mutex);

            ctx->node = NULL;
        }

        /* 此处返回的status_code即503(NGX_HTTP_SERVICE_UNAVAILABLE) */
        return lrcf->status_code;
    }

    ...
}


static char *
ngx_http_limit_req_merge_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ...
    /* 限流模块返回的错误码其默认值在此处设置 */
    ngx_conf_merge_uint_value(conf->status_code, prev->status_code,
                              NGX_HTTP_SERVICE_UNAVAILABLE)
    ...
}


static ngx_int_t
ngx_http_limit_req_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    /* 关注此处，限流模块位于11个阶段中的PREACCESS阶段 */
    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PREACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_limit_req_handler;

    return NGX_OK;
}

~~~

ngx_http_limit_req_handler中，限流模块经过漏桶算法后，若当前请求数量已超过阀值即NGX_BUSY，则该函数返回lrcf->status_code，即503。

而通过ngx_http_limit_req_init可知，限流模块位于NGINX处理HTTP请求11个阶段中的PREACCESS阶段，于是返回至ngx_http_limit_req_handler的调用者，即ngx_http_core_access_phase函数。

~~~

ngx_int_t
ngx_http_core_access_phase(ngx_http_request_t *r, ngx_http_phase_handler_t *ph)
{
    ngx_int_t                  rc;
    ngx_http_core_loc_conf_t  *clcf;

    if (r != r->main) {
        r->phase_handler = ph->next;
        return NGX_AGAIN;
    }

    ngx_log_debug1(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "access phase: %ui", r->phase_handler);

    /* ngx_http_limit_req_handler在这里被调用，即当前请求被限流时，rc的值为503 */
    rc = ph->handler(r);

    if (rc == NGX_DECLINED) {
        r->phase_handler++;
        return NGX_AGAIN;
    }

    if (rc == NGX_AGAIN || rc == NGX_DONE) {
        return NGX_OK;
    }

    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (clcf->satisfy == NGX_HTTP_SATISFY_ALL) {

        if (rc == NGX_OK) {
            r->phase_handler++;
            return NGX_AGAIN;
        }

    } else {
        if (rc == NGX_OK) {
            r->access_code = 0;

            if (r->headers_out.www_authenticate) {
                r->headers_out.www_authenticate->hash = 0;
            }

            r->phase_handler = ph->next;
            return NGX_AGAIN;
        }

        if (rc == NGX_HTTP_FORBIDDEN || rc == NGX_HTTP_UNAUTHORIZED) {
            if (r->access_code != NGX_HTTP_UNAUTHORIZED) {
                r->access_code = rc;
            }

            r->phase_handler++;
            return NGX_AGAIN;
        }
    }

    /* rc == NGX_HTTP_SERVICE_UNAVAILABLE，于是当前请求执行至此，即将调用ngx_http_finalize_request */

    /* rc == NGX_ERROR || rc == NGX_HTTP_...  */

    ngx_http_finalize_request(r, rc);
    return NGX_OK;
}

~~~


ngx_http_core_access_phase是限流模块的真正调用者，当ph->handler(r)返回NGX_HTTP_SERVICE_UNAVAILABLE时，证明该请求已经处理完毕，即将被释放，于是ngx_http_finalize_request函数将被调用来结束该请求，无需关心ngx_http_finalize_request的返回值，当其调用结束后，响应已经被发送，所以我们无需再关心ngx_http_core_access_phase返回之后的事情了，我们真正重点需要关注的是ngx_http_finalize_request中生成响应的逻辑。


~~~

void
ngx_http_finalize_request(ngx_http_request_t *r, ngx_int_t rc)
{
    ngx_connection_t          *c;
    ngx_http_request_t        *pr;
    ngx_http_core_loc_conf_t  *clcf;

    c = r->connection;

    ngx_log_debug5(NGX_LOG_DEBUG_HTTP, c->log, 0,
                   "http finalize request: %i, \"%V?%V\" a:%d, c:%d",
                   rc, &r->uri, &r->args, r == c->data, r->main->count);

    /* rc = NGX_HTTP_SERVICE_UNAVAILABLE，所以函数将继续执行 */
    if (rc == NGX_DONE) {
        ngx_http_finalize_connection(r);
        return;
    }

    if (rc == NGX_OK && r->filter_finalize) {
        c->error = 1;
    }

    if (rc == NGX_DECLINED) {
        r->content_handler = NULL;
        r->write_event_handler = ngx_http_core_run_phases;
        ngx_http_core_run_phases(r);
        return;
    }

    /* 当前请求即将被结束，无需关心其子请求，所以忽略此处条件 */
    if (r != r->main && r->post_subrequest) {
        rc = r->post_subrequest->handler(r, r->post_subrequest->data, rc);
    }

    if (rc == NGX_ERROR
        || rc == NGX_HTTP_REQUEST_TIME_OUT
        || rc == NGX_HTTP_CLIENT_CLOSED_REQUEST
        || c->error)
    {
        if (ngx_http_post_action(r) == NGX_OK) {
            return;
        }

        if (r->main->blocked) {
            r->write_event_handler = ngx_http_request_finalizer;
        }

        ngx_http_terminate_request(r, rc);
        return;
    }

    /* OK， 终于执行到此处 */
    /* NGX_HTTP_SPECIAL_RESPONSE = 300，所以503 > 300 成立 */
    if (rc >= NGX_HTTP_SPECIAL_RESPONSE
        || rc == NGX_HTTP_CREATED
        || rc == NGX_HTTP_NO_CONTENT)
    {
        if (rc == NGX_HTTP_CLOSE) {
            ngx_http_terminate_request(r, rc);
            return;
        }

        if (r == r->main) {
            if (c->read->timer_set) {
                ngx_del_timer(c->read);
            }

            if (c->write->timer_set) {
                ngx_del_timer(c->write);
            }
        }

        c->read->handler = ngx_http_request_handler;
        c->write->handler = ngx_http_request_handler;

        /* 关注ngx_http_special_response_handler，错误页面的真正生成者 */
        /* 在ngx_http_special_response_handler返回后，响应已经发出，请求将被真正释放 */
        ngx_http_finalize_request(r, ngx_http_special_response_handler(r, rc));
        return;
    }
    
    ...

}

~~~


ngx_http_finalize_request函数在此情况下并不复杂，当其参数rc为503时，ngx_http_special_response_handler将被调用来生成和发送响应，ngx_http_finalize_request最终的宿命仅仅需要释放请求资源而已，我们暂不关注其它逻辑，因为对于错误页面的影响不大。


~~~

ngx_int_t
ngx_http_special_response_handler(ngx_http_request_t *r, ngx_int_t error)
{
    ngx_uint_t                 i, err;
    ngx_http_err_page_t       *err_page;
    ngx_http_core_loc_conf_t  *clcf;

    ngx_log_debug3(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "http special response: %i, \"%V?%V\"",
                   error, &r->uri, &r->args);

    r->err_status = error;

    /* keepalive和lingering_close不影响错误页面的逻辑 */
    if (r->keepalive) {
        switch (error) {
            case NGX_HTTP_BAD_REQUEST:
            case NGX_HTTP_REQUEST_ENTITY_TOO_LARGE:
            case NGX_HTTP_REQUEST_URI_TOO_LARGE:
            case NGX_HTTP_TO_HTTPS:
            case NGX_HTTPS_CERT_ERROR:
            case NGX_HTTPS_NO_CERT:
            case NGX_HTTP_INTERNAL_SERVER_ERROR:
            case NGX_HTTP_NOT_IMPLEMENTED:
                r->keepalive = 0;
        }
    }

    if (r->lingering_close) {
        switch (error) {
            case NGX_HTTP_BAD_REQUEST:
            case NGX_HTTP_TO_HTTPS:
            case NGX_HTTPS_CERT_ERROR:
            case NGX_HTTPS_NO_CERT:
                r->lingering_close = 0;
        }
    }

    r->headers_out.content_type.len = 0;

    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    /* 关注此处，当nginx.conf中存在当前请求的任一错误页面时，前两个条件已经成立，clcf->error_pages数组中起码存在某个错误页 */
    /* r->uri_changes用来保证请求不会无限跳转，所以影响不大 */
    if (!r->error_page && clcf->error_pages && r->uri_changes != 0) {

        if (clcf->recursive_error_pages == 0) {
            r->error_page = 1;
        }

        err_page = clcf->error_pages->elts;

        /* 遍历clcf->error_pages，寻找匹配503错误码的错误页 */
        for (i = 0; i < clcf->error_pages->nelts; i++) {
            /* 如果找到503的错误页面配置，则将调用ngx_http_send_error_page */
            /* 如果未配置503的错误页，则条件不成立 */
            if (err_page[i].status == error) {
                return ngx_http_send_error_page(r, &err_page[i]);
            }
        }
    }

    r->expect_tested = 1;

    if (ngx_http_discard_request_body(r) != NGX_OK) {
        r->keepalive = 0;
    }

    if (clcf->msie_refresh
        && r->headers_in.msie
        && (error == NGX_HTTP_MOVED_PERMANENTLY
            || error == NGX_HTTP_MOVED_TEMPORARILY))
    {
        return ngx_http_send_refresh(r);
    }

    if (error == NGX_HTTP_CREATED) {
        /* 201 */
        err = 0;

    } else if (error == NGX_HTTP_NO_CONTENT) {
        /* 204 */
        err = 0;

    } else if (error >= NGX_HTTP_MOVED_PERMANENTLY
               && error < NGX_HTTP_LAST_3XX)
    {
        /* 3XX */
        err = error - NGX_HTTP_MOVED_PERMANENTLY + NGX_HTTP_OFF_3XX;

    } else if (error >= NGX_HTTP_BAD_REQUEST
               && error < NGX_HTTP_LAST_4XX)
    {
        /* 4XX */
        err = error - NGX_HTTP_BAD_REQUEST + NGX_HTTP_OFF_4XX;

    } else if (error >= NGX_HTTP_NGINX_CODES
               && error < NGX_HTTP_LAST_5XX)
    {
        /* 49X, 5XX */
        err = error - NGX_HTTP_NGINX_CODES + NGX_HTTP_OFF_5XX;
        switch (error) {
            case NGX_HTTP_TO_HTTPS:
            case NGX_HTTPS_CERT_ERROR:
            case NGX_HTTPS_NO_CERT:
            case NGX_HTTP_REQUEST_HEADER_TOO_LARGE:
                r->err_status = NGX_HTTP_BAD_REQUEST;
                break;
        }

    } else {
        /* unknown code, zero body */
        err = 0;
    }

    /* 未配置错误页，则最终将会去找NGINX默认为503等错误码准备的页面 */
    return ngx_http_send_special_response(r, clcf, err);
}

~~~

ngx_http_special_response_handler将会去寻找配置文件中配置的错误码和错误页面，如果找到对应的配置项，则会调用ngx_http_send_error_page函数，如果未配置对应的错误码和错误页面，则将调用ngx_http_send_special_response来生成默认页面，默认页面是NGINX在内存中早已写死的页面，ngx_http_send_special_response后面还会用到，稍后再分析。

OK，分析到这里，其实已经把error_page的配置项和实际请求的代码流程结合起来了，下面分析如何利用配置项生成响应。


~~~

static ngx_int_t
ngx_http_send_error_page(ngx_http_request_t *r, ngx_http_err_page_t *err_page)
{
    ngx_int_t                  overwrite;
    ngx_str_t                  uri, args;
    ngx_table_elt_t           *location;
    ngx_http_core_loc_conf_t  *clcf;

    overwrite = err_page->overwrite;

    if (overwrite && overwrite != NGX_HTTP_OK) {
        r->expect_tested = 1;
    }

    if (overwrite >= 0) {
        r->err_status = overwrite;
    }

    if (ngx_http_complex_value(r, &err_page->value, &uri) != NGX_OK) {
        return NGX_ERROR;
    }

    /* 静态错误页一般是/50x.html这种，所以若是'/'开头的URI，则条件成立 */
    if (uri.len && uri.data[0] == '/') {

        if (err_page->value.lengths) {
            ngx_http_split_args(r, &uri, &args);

        } else {
            args = err_page->args;
        }

        if (r->method != NGX_HTTP_HEAD) {
            r->method = NGX_HTTP_GET;
            r->method_name = ngx_http_core_get_method;
        }

        /* NGINX处理静态错误页利用了内部跳转的机制 */
        return ngx_http_internal_redirect(r, &uri, &args);
    }


    /* 错误页如果是命名location形式，则条件成立 */
    if (uri.len && uri.data[0] == '@') {
    	/* 命名location形式其实和内部跳转类似，都是去调用11个阶段完成响应的生成 */
        return ngx_http_named_location(r, &uri);
    }

    /* 外部错误页如http://example.com/forbidden.html这种形式NGINX将直接重定向，所以此处将状态码设置为302(NGX_HTTP_MOVED_TEMPORARILY)，且需要设置HTTP Header中的Location字段，HTML页面也就是简单的302 FOUND，所以响应内容为NGINX内存中已经准备好的页面 */

    location = ngx_list_push(&r->headers_out.headers);

    if (location == NULL) {
        return NGX_ERROR;
    }

    if (overwrite != NGX_HTTP_MOVED_PERMANENTLY
        && overwrite != NGX_HTTP_MOVED_TEMPORARILY
        && overwrite != NGX_HTTP_SEE_OTHER
        && overwrite != NGX_HTTP_TEMPORARY_REDIRECT)
    {
        r->err_status = NGX_HTTP_MOVED_TEMPORARILY;
    }

    location->hash = 1;
    ngx_str_set(&location->key, "Location");
    location->value = uri;

    ngx_http_clear_location(r);

    r->headers_out.location = location;

    clcf = ngx_http_get_module_loc_conf(r, ngx_http_core_module);

    if (clcf->msie_refresh && r->headers_in.msie) {
        return ngx_http_send_refresh(r);
    }

    return ngx_http_send_special_response(r, clcf, r->err_status
                                                   - NGX_HTTP_MOVED_PERMANENTLY
                                                   + NGX_HTTP_OFF_3XX);
}

~~~


ngx_http_send_error_page负责真正处理本文开头所总结的三种情况：

- 内部错误页：将会调用ngx_http_internal_redirect实现内部跳转，其真正的逻辑是调用static模块完成静态文件的查找和读取或者反向代理模块完成响应的生成

- 外部错误页：NGINX对于外部错误页的处理比较简单，直接重定向，由客户端的浏览器完成跳转

- 未配置：NGINX为很多错误码准备好的默认的错误页，当未配置时将默认发送其内容，如下所示：

~~~

static char ngx_http_error_302_page[] =
"<html>" CRLF
"<head><title>302 Found</title></head>" CRLF
"<body bgcolor=\"white\">" CRLF
"<center><h1>302 Found</h1></center>" CRLF
;

~~~

ngx_http_internal_redirect和ngx_http_named_location的逻辑稍有不同，前者仅需直接调用ngx_http_handler重走11个阶段即可，后者利用命名location来实现响应的生成，因为NGINX在生成location tree的时候把static location、regex location和named location区别对待，普通请求在匹配location的时候其实只会寻找location tree中的static location，而regex location和named location不参与location tree的构建，因此ngx_http_named_location需要做的就是从cscf->named_locations匹配到命名location，然后再调用ngx_http_core_run_phases来完成11个阶段剩余的阶段(从NGX_HTTP_REWRITE_PHASE开始)。

~~~

ngx_int_t
ngx_http_internal_redirect(ngx_http_request_t *r,
    ngx_str_t *uri, ngx_str_t *args)
{
    ngx_http_core_srv_conf_t  *cscf;

    /* 内部重定向，NGINX为防止请求的无限内部跳转，限定了内部重定向次数的上限为NGX_HTTP_MAX_URI_CHANGES + 1 */
    r->uri_changes--;

    if (r->uri_changes == 0) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "rewrite or internal redirection cycle "
                      "while internally redirecting to \"%V\"", uri);

        r->main->count++;
        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return NGX_DONE;
    }


    /* 内部重定向前修改请求的URI */
    r->uri = *uri;

    if (args) {
        r->args = *args;

    } else {
        ngx_str_null(&r->args);
    }

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "internal redirect: \"%V?%V\"", uri, &r->args);

    ngx_http_set_exten(r);

    /* clear the modules contexts */
    ngx_memzero(r->ctx, sizeof(void *) * ngx_http_max_module);

    cscf = ngx_http_get_module_srv_conf(r, ngx_http_core_module);
    r->loc_conf = cscf->ctx->loc_conf;

    ngx_http_update_location_config(r);

#if (NGX_HTTP_CACHE)
    r->cache = NULL;
#endif

    r->internal = 1;
    r->valid_unparsed_uri = 0;
    r->add_uri_to_alias = 0;
    r->main->count++;

    /* URI已经被修改，重新执行一遍请求的11个阶段 */
    ngx_http_handler(r);

    return NGX_DONE;
}

~~~


~~~

ngx_int_t
ngx_http_named_location(ngx_http_request_t *r, ngx_str_t *name)
{
    ngx_http_core_srv_conf_t    *cscf;
    ngx_http_core_loc_conf_t   **clcfp;
    ngx_http_core_main_conf_t   *cmcf;

    /* 增加主请求的引用数，这个字段主要是在ngx_http_finalize_request调用的一些结束请求和连接的函数中使用 */
    r->main->count++;
    /* 内部重定向，NGINX为防止请求的无限内部跳转，限定了内部重定向次数的上限为NGX_HTTP_MAX_URI_CHANGES + 1 */
    r->uri_changes--;

    if (r->uri_changes == 0) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "rewrite or internal redirection cycle "
                      "while redirect to named location \"%V\"", name);

        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return NGX_DONE;
    }

    if (r->uri.len == 0) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "empty URI in redirect to named location \"%V\"", name);

        ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);
        return NGX_DONE;
    }

    cscf = ngx_http_get_module_srv_conf(r, ngx_http_core_module);

    /* 从cscf->named_locations匹配到命名location */
    if (cscf->named_locations) {

        for (clcfp = cscf->named_locations; *clcfp; clcfp++) {

            ngx_log_debug1(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                           "test location: \"%V\"", &(*clcfp)->name);

            if (name->len != (*clcfp)->name.len
                || ngx_strncmp(name->data, (*clcfp)->name.data, name->len) != 0)
            {
                continue;
            }

            ngx_log_debug3(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                           "using location: %V \"%V?%V\"",
                           name, &r->uri, &r->args);

            r->internal = 1;
            r->content_handler = NULL;
            r->uri_changed = 0;
            r->loc_conf = (*clcfp)->loc_conf;

            /* clear the modules contexts */
            ngx_memzero(r->ctx, sizeof(void *) * ngx_http_max_module);

            ngx_http_update_location_config(r);

            cmcf = ngx_http_get_module_main_conf(r, ngx_http_core_module);

            /* 上面的流程替代了默认的NGX_HTTP_FIND_CONFIG_PHASE阶段 */
            r->phase_handler = cmcf->phase_engine.location_rewrite_index;

            r->write_event_handler = ngx_http_core_run_phases;

            /* 完成了location的匹配后接着执行11个阶段剩下的阶段 */
            ngx_http_core_run_phases(r);

            return NGX_DONE;
        }
    }

    ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                  "could not find named location \"%V\"", name);

    ngx_http_finalize_request(r, NGX_HTTP_INTERNAL_SERVER_ERROR);

    return NGX_DONE;
}

~~~


~~~

static ngx_int_t
ngx_http_send_special_response(ngx_http_request_t *r,
    ngx_http_core_loc_conf_t *clcf, ngx_uint_t err)
{
    u_char       *tail;
    size_t        len;
    ngx_int_t     rc;
    ngx_buf_t    *b;
    ngx_uint_t    msie_padding;
    ngx_chain_t   out[3];

    if (clcf->server_tokens) {
        len = sizeof(ngx_http_error_full_tail) - 1;
        tail = ngx_http_error_full_tail;

    } else {
        len = sizeof(ngx_http_error_tail) - 1;
        tail = ngx_http_error_tail;
    }

    msie_padding = 0;

    /* ngx_http_error_pages数组中保存了默认的错误页内容，其实就是字符串 */
    if (ngx_http_error_pages[err].len) {
        r->headers_out.content_length_n = ngx_http_error_pages[err].len + len;
        if (clcf->msie_padding
            && (r->headers_in.msie || r->headers_in.chrome)
            && r->http_version >= NGX_HTTP_VERSION_10
            && err >= NGX_HTTP_OFF_4XX)
        {
            r->headers_out.content_length_n +=
                                         sizeof(ngx_http_msie_padding) - 1;
            msie_padding = 1;
        }

        r->headers_out.content_type_len = sizeof("text/html") - 1;
        ngx_str_set(&r->headers_out.content_type, "text/html");
        r->headers_out.content_type_lowcase = NULL;

    } else {
        r->headers_out.content_length_n = 0;
    }

    if (r->headers_out.content_length) {
        r->headers_out.content_length->hash = 0;
        r->headers_out.content_length = NULL;
    }

    ngx_http_clear_accept_ranges(r);
    ngx_http_clear_last_modified(r);
    ngx_http_clear_etag(r);

    /* 调用filter模块发送响应的头部 */
    rc = ngx_http_send_header(r);

    if (rc == NGX_ERROR || r->header_only) {
        return rc;
    }

    if (ngx_http_error_pages[err].len == 0) {
        return ngx_http_send_special(r, NGX_HTTP_LAST);
    }

    /* 将默认错误页的内容拷贝至内存中作为响应body准备发送 */
    b = ngx_calloc_buf(r->pool);
    if (b == NULL) {
        return NGX_ERROR;
    }

    b->memory = 1;
    b->pos = ngx_http_error_pages[err].data;
    b->last = ngx_http_error_pages[err].data + ngx_http_error_pages[err].len;

    out[0].buf = b;
    out[0].next = &out[1];

    b = ngx_calloc_buf(r->pool);
    if (b == NULL) {
        return NGX_ERROR;
    }

    b->memory = 1;

    b->pos = tail;
    b->last = tail + len;

    out[1].buf = b;
    out[1].next = NULL;

    if (msie_padding) {
        b = ngx_calloc_buf(r->pool);
        if (b == NULL) {
            return NGX_ERROR;
        }

        b->memory = 1;
        b->pos = ngx_http_msie_padding;
        b->last = ngx_http_msie_padding + sizeof(ngx_http_msie_padding) - 1;

        out[1].next = &out[2];
        out[2].buf = b;
        out[2].next = NULL;
    }

    if (r == r->main) {
        b->last_buf = 1;
    }

    b->last_in_chain = 1;

    /* 调用filter模块发送响应的body */
    return ngx_http_output_filter(r, &out[0]);
}

~~~


NGINX错误页面的源码流程基本上分析完毕，总结一下：

- 内部错误页：找到错误页面配置项后内部重定向完成响应的生成

- 外部错误页：找到错误页面配置项后构造302响应，由客户端浏览器完成重定向；

- 未配置：找不到错误页面的配置项，响应内容为NGINX默认的页面内容

{% include references.md %}