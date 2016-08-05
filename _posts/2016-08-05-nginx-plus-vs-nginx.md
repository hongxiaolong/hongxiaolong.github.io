---
layout: post
title: NGINX PLUS vs NGINX
category: tech
---

首先简单回顾下NGINX的版本和历史：

* 2002年，来自俄罗斯的Igor Sysoev使用C语言开发了NGINX；

* 2004年，NGINX开放源码，基于BSD开源许可。

* 2006年 - 2016年，NIGNX Rlease版本历经0.5, 0.6, 0.7, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 1.9, 1.10, 1.11, 当前最新版本为1.11.3；

* 2011年，Sysoev成立了NGINX公司，NGINX PLUS是其第一款产品，也是NGINX的商业版本；

* 2013年 - 2016年，自NGINX Plus Initial Release (R1)版本发布以来，NGINX商业版本已更新至NGINX Plus Release 9 (R9)；

在双重协议下，NGINX PLUS在开源版本NGINX基础之上增加了若干新特性和新功能，其[官方网站](https://www.nginx.com)为其定义为：

> [NGINX Plus is the all-in-one application delivery platform for the modern web.](https://www.nginx.com/products/)

总的来说，all-in-one的NGINX PLUS对比开源版本重点增加了若干企业特性，包括更完善的七层、四层负载均衡，会话保持，健康检查，实时监控和管理等。

下面我们可以从两个方面来对比NGINX PLUS和NGINX，暂时忽略其它非技术层面的区别：

* 运维特性，其实就是NGINX实例的安装和升级方式；

* 功能特性，也就是从技术角度分析两者的模块和服务；

## 运维特性

众所周知，开源软件的运维特性往往无法称心如意，毕竟一千个读者眼里有一千个哈姆雷特，不同的用户对于NGINX的应用方式也千差万别。但是总的来说，常见的场景无非是RPM或者源码安装。NGINX在CentOS或者Ubuntu这样的Linux发行版本上都早已经提供了RPM方式的安装和升级方式，用户只需要简单地执行

~~~
$ yum install nginx
~~~

或者

~~~
$ apt-get install nginx
~~~

即可完成相应版本NGINX的安装。

但若是需要定制NGINX或者二次开发的话，则源码方式配合自动化运维工具如ansible明显才是首选，在这里不再赘述NGINX的运维特性，Google一下，你就知道~

也可参考笔者曾经的自动化运维代码：[A Complete ansible playbook (more than roles) for nginx](https://github.com/hongxiaolong/ansible-nginx)

下面来介绍NGINX PLUS的运维特性，其实说白了就是因为商业版本收费导致的认证差异。

NGINX PLUS是以单实例收费，且费用不菲，而且因为不开放源码的原因，其安装方式也就限制于RPM。

NGINX PLUS提供[30天免费试用版本](https://www.nginx.com/free-trial-request-summary/)。

参考笔者在CentOS 7.0上的安装步骤：

1. 如果曾经已安装过NGINX PLUS，则首先备份一下原有的证书：

   ~~~
   $ sudo cp -a /etc/nginx /etc/nginx-plus-backup
   $ sudo cp -a /var/log/nginx /var/log/nginx-plus-backup
   ~~~

2. 创建NIGNX PLUS证书目录：

   ~~~
   $ sudo mkdir -p /etc/ssl/nginx
   ~~~

3. 登录NGINX PLUS官网[NGINX Customer Portal](https://cs.nginx.com/)下载证书：

   * nginx-repo.key
   
   * nginx-repo.crt

4. 将NGINX PLUS的证书拷贝至证书目录：

   ~~~
   $ sudo cp nginx-repo.key nginx-repo.crt /etc/ssl/nginx
   ~~~

5. 安装认证组件：

   ~~~
   $ sudo yum install ca-certificates
   ~~~

6. 下载NGINX PLUS YUM源[nginx-plus-7.repo](https://cs.nginx.com/static/files/nginx-plus-7.repo)至/etc/yum.repos.d：

   ~~~
   $ sudo wget -P /etc/yum.repos.d https://cs.nginx.com/static/files/nginx-plus-7.repo
   ~~~

7. YUM安装NGINX PLUS：

   ~~~
   $ sudo yum install nginx-plus
   ~~~

8. 确认NGINX PLUS版本，我们可以明显看到NGINX PLUS的all-in-one特性，其安装的时候已默认集成绝大部分常用模块：

   ~~~
   $ nginx -V
   nginx version: nginx/1.9.13 (nginx-plus-r9-p1)
   built by gcc 4.8.5 20150623 (Red Hat 4.8.5-4) (GCC)
   built with OpenSSL 1.0.1e-fips 11 Feb 2013
   TLS SNI support enabled
   configure arguments: --build=nginx-plus-r9-p1 --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --modules-path=/usr/lib64/nginx/modules --conf-path=/etc/nginx/nginx.conf    --error-log-path=/var/log/nginx/error.log--http-log-path=/var/log/nginx/access.log --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock    --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp --http-scgi-temp-path=/var/cache/nginx/scgi_temp --user=nginx --group=nginx --with-http_ssl_module --with-http_v2_module    --with-http_realip_module --with-http_addition_module --with-http_sub_module --with-http_dav_module --with-http_flv_module --with-http_mp4_module --with-http_gzip_static_   module --with-http_gunzip_module --with-http_random_index_module --with-http_secure_link_module --with-http_stub_status_module --with-http_auth_request_module --with-http_   slice_module --with-mail --with-mail_ssl_module --with-threads --with-file-aio --with-ipv6 --with-stream --with-stream_ssl_module --with-http_f4f_module --with-http_session   _log_module --with-http_hls_module --with-http_xslt_module=dynamic --with-http_geoip_module=dynamic --with-http_image_filter_module=dynamic --with-http_perl_module=dynamic    --add-dynamic-module=ngx_devel_kit-0.3.0rc1 --add-dynamic-module=set-misc-nginx-module-0.30 --add-dynamic-module=lua-nginx-module-0.10.2    --add-dynamic-module=headers-more-nginx-module-0.29 --add-dynamic-module=nginx-rtmp-module-1.1.7 --add-dynamic-module=passenger-5.0.26/src/nginx_module --with-cc-opt='-O2    -g -pipe -Wall -Wp,-D_FORTIFY_SOURCE=2 -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches -m64 -mtune=generic'

   ~~~

9. 若需要更新NGINX PLUS版本，可直接通过YUM即可：

   ~~~
   $ sudo yum upgrade nginx-plus
   ~~~

从以上可知，NGINX PLUS对比NIGNX，增加了实例的CA认证，且受限于闭源，虽然无法做到开源版本NGINX的自由可定制，但其运维成本也极低。

## 功能特性

NGINX PLUS官方列举了商业版本对比开源版本NGINX新增特性如下：

> NGINX Plus extends open source NGINX with additional performance and security features, and includes support from the NGINX team to get your apps up and running in no time.

> * High-performance load balancing
> 
> * Intelligent session persistence
> 
> * Application-aware health checks
> 
> * High availability deployment modes
> 
> * Massively scalable content caching
> 
> * Sophisticated streaming media
> 
> * Advanced activity monitoring
> 
> * DevOps on-the-fly reconfiguration

我们逐条分析其模块及服务：

#### 四层、七层负载均衡：

NGINX 1.9版本增加了stream模块，使得NGINX也支持四层的TCP, UDP负载均衡，NIGNX PLUS在此基础之上还增加了若干特性支持更多的策略和功能。

- NGINX PLUS R9版本支持如下负载均衡策略：

  * Round-Robin (the default) 
  
  * Least Connections
  
  * Least Time 
  
  * Generic Hash 
  
  * IP Hash

  其实第三方模块基本上早已实现上述负载均衡策略，只需将对应模块编译到NIGNX中即可。一些第三方模块，如[Tengine的一致性HASH模块](http://tengine.taobao.org/document_cn/  http_upstream_consistent_hash_cn.html)，[fair模块](https://github.com/gnosek/nginx-upstream-fair)等，甚至比NGINX PLUS支持更多的负载均衡策略，所以在策略上NGINX   PLUS并没有什么优势。

- NGINX PLUS新增特性支持限流队列：

  ~~~
  upstream backend {
      zone backends 64k;
      queue 750 timeout=30s;
  
      server webserver1 max_conns=250;
      server webserver2 max_conns=150;
  }
  ~~~
  
  配置如上限流策略（有别于NGINX的限流模块）后，当分流至对应上游服务器的连接数量超过max_conns时，NGINX   PLUS将所有新的连接暂存至队列中，一旦有连接被释放时，则优先处理暂存队列中的请求。
  
  配置项：
  
  * queue: 暂存队列的上限，如上，可暂存最多750个连接；
  
  * timeout: 暂存连接的超时时间，如上，当连接暂存超过30秒仍未处理，直接丢弃；
  
  * max_conns: 上游服务器同时可承载的连接上限，如上，webserver1最多可以同时存在250个连接；

  NGINX PLUS的限流队列和NGINX限流模块的delay模式有那么点异曲同工之妙，可以对比NGINX限流模块的delay模式，前者的限流队列明显更可控，功能更强大。

  ~~~
  #速率qps=1，峰值burst=5，延迟请求

  limit_req_zone  $binary_remote_addr  zone=qps1:1m   rate=1r/s;

  location /delay {
      limit_req   zone=qps1  burst=5;
  }

  #在峰值burst=5以内的并发请求，会被挂起，延迟处理
  #严格按照漏桶速率qps=1处理每秒请求
  # 例：发起一个并发请求=6，拒绝1个，处理1个，进入延迟队列4个：
  #time    request    refuse    sucess    delay
  #00:01      6          1        1         4
  #00:02      0          0        1         3
  #00:03      0          0        1         2
  #00:04      0          0        1         1
  #00:05      0          0        1         0
  ~~~

  未完待续..


{% include references.md %}
