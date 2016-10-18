---
layout: post
title: VPN in Vultr VPS
category: tech
---

AWS的VPS到期了，对于猿来说，无法访问墙外服务如Google简直是工作效率的无形杀手..

于是乎，to keep on with AWS or to try others, that is a question..

在AWS上搭梯子说实话也有点费劲（当然现在已经越来越无脑了..），特别是需求在那里，PC上的shadowsocks和iPhone、iPad上的IPsec，缺一不可..

既然如此，借此机会，正好练练笔的同时也做个备忘，此文应运而生..

如能给同道中人些许帮助，也不胜荣幸~~


### 引子

不想很俗套地去介绍VPS的选择了，毕竟萝卜白菜各有所爱，AWS、Linode、DigitalOcean，Vultr、BandwagonHost and so on..

综合对比，国外的VPS其实也各有优劣，还有其相关的虚拟化技术也五花八门，kvm、xen、openvz都有涉及，超配也是家常便饭..

引子就简单介绍下如何快速便捷地检测到底是采用了哪种虚拟化技术：

~~~
# 在Vultr Vultr - CentOS 7.0 x64上来个示例：

$ sudo yum install virt-what

$ virt-what

kvm
~~~

很明显，我的这台Vultr VPS基于kvm。

知乎有很多VPS横向纵向对比的问答，如：

[有哪些便宜稳定，速度也不错的Linux VPS 推荐？](https://www.zhihu.com/question/20800554)

[有哪些好用的美国 VPS 或者独立主机？](https://www.zhihu.com/question/19799215)

所以在这里我就不再赘述了，我已暂时告别AWS，选择了Vultr..


### Shadowsocks

Shadowsocks应该是PC上最多的选择吧，安装简单，使用便捷，在线和离线的PAC可以保证墙内流量和墙外流量互不干扰，而且Windows和Mac的都有支持的客户端（吐槽Mac上的Shadowsocks图标真心影响那一排美观的工具栏图标..）。

- Python安装Shadowsocks：

  ~~~
  $ sudo pip install shadowsocks
  
  $ sudo mkdir /usr/local/shadowsocks
  
  $ sudo vim /usr/local/shadowsocks/config.json
  
  {
      "server":"0.0.0.0",
      "server_port":8388,
      "local_address":"127.0.0.1",
      "local_port":1080,
      "password":"password",
      "timeout":300,
      "method":"aes-256-cfb",
      "fast_open":false
  }
  
  $ cd /usr/local/shadowsocks
  
  $ sudo nohup ssserver > shadowsocks.log &
  ~~~

  如果Python很熟悉的话只需要上面简单的几个步骤，VPS上的Shadowsocks服务就已经运行起来了，剩下的只要简单配置客户端即可。

- 脚本安装Shadowsocks

  如果Python也不知道是什么东东，或者python-pip也不知所云，甚至只喜欢偷懒的一键XXX，那么脚本安装明显最佳选择。

  ~~~

  # 可以参考[teddysun的安装脚本](https://github.com/teddysun/shadowsocks_install)

  $ wget –no-check-certificate https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocks.sh

  # 添加执行权限

  $ sudo chmod +x shadowsocks.sh

  # 按照脚本提示输入翻墙所需参数，其实也就是config.json中的内容

  $ sudo ./shadowsocks.sh 2>&1 | tee shadowsocks.log

  # 安装后已添加shadowsocks服务至启动脚本

  $ sudo /etc/init.d/shadowsocks status

  ~~~

- Docker或者其它方式：

  Shadowsocks也支持docker镜像直接部署：

  ~~~
  $ sudo docker search shadowsocks

  NAME                              DESCRIPTION                                     STARS     OFFICIAL   AUTOMATED
  oddrationale/docker-shadowsocks   shadowsocks Docker image                        86                   [OK]
  tommylau/shadowsocks                                                              44                   [OK]
  vimagick/shadowsocks-libev        A lightweight secured socks5 proxy for emb...   39                   [OK]
  shadowsocks/shadowsocks-libev                                                     27                   [OK]
  vimagick/shadowsocks              A secure socks5 proxy, designed to protect...   9                    [OK]
  menghan/shadowsocks               shadowsocks server                              6                    [OK]
  imlonghao/shadowsocks-libev       A docker image for shadowsocks-libev            4                    [OK]
  registercn/shadowsocks-libev      Shadowsocks-libev on Alpine Linux               3                    [OK]
  frankzhang/shadowsocks-c          A shadowsocks repo, https://github.com/zju...   2                    [OK]
  jamespan/shadowsocks-go           Image for shadowsocks-go                        1                    [OK]
  gaoyifan/shadowsocks-manyuser     shadowsocks manyuser                            1                    [OK]
  chenzhiwei/shadowsocks            Shadowsocks socket proxy. (Image size 77M)      1                    [OK]
  bluebu/shadowsocks-privoxy        shadowsocks client for socks5 proxy privox...   1                    [OK]
  baselibrary/shadowsocks           shadowsocks                                     1                    [OK]
  wengcan/shadowsocks               shadowsocks libev                               1                    [OK]
  imwithye/shadowsocks              Docker Container for Shadowsocks                0                    [OK]
  leizongmin/shadowsocks            shadowsocks server                              0                    [OK]
  gaoyifan/shadowsocks-libev        shadowsocks-libev                               0                    [OK]
  zhusj/shadowsocks                 shadowsocks-libev server                        0                    [OK]
  princeofdatamining/shadowsocks    shadowsocks                                     0                    [OK]
  yikyo/shadowsocks                 shadowsocks                                     0                    [OK]
  kotaimen/shadowsocks              Shadowsocks server                              0                    [OK]
  hbrls/shadowsocks                 shadowsocks                                     0                    [OK]
  fevenor/shadowsocks               Shadowsocks Dockerized                          0                    [OK]
  yikyo/shadowsocks-client          shadowsocks-client                              0                    [OK]
  ~~~

  可以直接采用上述docker镜像安装shadowsocks，我在Vultr VPS - CentOS 7.0 x64上尝试过上述若干镜像，~~*有时候无法顺利安装或者运行shadowsocks服务，而且不管Python安装还是脚本安装，已经足够简单便捷，所以有兴趣的同学自己尝试吧，有机会我再继续完善（2016年8月18日已完善，如下）*~~。

  其实看了下STARS最多的oddrationale/docker-shadowsocks源码，简单得令人发指..^^，所以我立马来更新一下这段，代码可以参考[作者Github](https://github.com/oddrationale/docker-shadowsocks)。

  Docker安装shadowssocks如下：

  ~~~

  # 首先在我的Vultr VPS上安装docker，其它平台或其它Linux发行版自行观摩[官方文档](https://docs.docker.com/engine/installation/)

  $ sudo yum install docker

  # 启动docker服务：

  $ sudo service docker start
  
  # 拉取docker镜像

  $ sudo docker pull oddrationale/docker-shadowsocks

  # docker启动shadowsocks容器，PORT和PASSWORD自行填写..

  $ sudo docker run --name shadowsocks-vpn-server -d -p $PORT:$PORT oddrationale/docker-shadowsocks -s 0.0.0.0 -p $PORT -k $PASSWORD -m aes-256-cfb

  # 可以通过docker容器的top命令或者日志观察shadowsocks服务状况

  $ sudo docker top shadowsocks-vpn-server

  $ sudo docker logs shadowsocks-vpn-server

  ~~~

  阅读过该docker镜像的Dockfile后，其实作者也就是在docker里安装了python-pip和shadowsocks，然后直接在bash中启动shadowsocks服务，仅此而已:

  ~~~

  # 启动shadowsocks服务，后面的参数可以直接跟在启动命令之后，也可放在config.json中

  $ /usr/local/bin/ssserver -s 0.0.0.0 -p $PORT -k $PASSWORD -m aes-256-cfb

  ~~~

  如果镜像在安装过程中报错，可以自行审阅日志，毕竟没几句命令..我在Vultr CentOS 7.0 x64中报过device mapper挂载错误，但是我查看过device mapper挺正常的..

### IPsec

如果只在PC上有翻墙需求，那么Shadowsocks已经足够好了，况且其实现在很多所谓的翻墙服务厂商也就是基于Shadowsocks去提供服务给用户的。

如果PC之外呢，类似Android、iPhone、iPad等移动设备，因为权限或者APP问题，Shadowsocks无法很好地满足需求，那么再搭配IPsec来使用再好不过了，毕竟将VPS的作用最大化，且不需要再安装其它的APP客户端（因为Android、iOS内置了IPsec客户端，在设置中配一下即可），简直不要太完美..

IPsec的安装和配置远比Shadowsocks复杂，而且换个环境可能配置方式也有很多不同，所以这里我不再详细介绍如何手动安装和配置IPsec服务了。

取而代之，我直接采用了Docker镜像来安装IPsec服务：

~~~
# 首先在我的Vultr VPS上安装docker，其它平台或其它Linux发行版自行观摩[官方文档](https://docs.docker.com/engine/installation/)

$ sudo yum install docker

# 启动docker服务：

$ sudo service docker start

# 现成的docker镜像也不少..

$ sudo docker search ipsec
NAME                               DESCRIPTION                                     STARS     OFFICIAL   AUTOMATED
hwdsl2/ipsec-vpn-server            VPN server with IPsec/L2TP and Cisco IPsec      15                   [OK]
cpuguy83/ipsec                                                                     6                    [OK]
ikoula/docker-l2tp-ipsec-vpn       Docker L2TP / IPSec VPN Client                  3
fcojean/l2tp-ipsec-vpn-server      A docker l2tp ipsec vpn server with multip...   2                    [OK]
r4ffy/ipsec                        Ipsec Server Docker-Version                     1
0xj9/l2tp-ipsec-vpn                                                                1                    [OK]
lotosbin/docker-ipsec-vpn-server   docker-ipsec-vpn-server                         1                    [OK]
r4ffy/ipsecclient                  Ipsec Client OpenSwan                           1
neter/docker-ipsec-vpn-server      docker-ipsec-vpn-server                         0                    [OK]
jpillora/ipsec-vpn-server          A simple, multi-user IPsec/L2TP and Cisco ...   0                    [OK]
chagridsada/multivpn-ipsec         Multiple vpn IPSec docker images                0
crewjam/ipsec                                                                      0
energy1190/ipsec-tools             ipsec-tools                                     0                    [OK]
free/ipsec                                                                         0
matrixanger/rpi-ipsec              L2TP/IPSec for RaspberryPi and other ARM c...   0
jim3mar/ipsec                                                                      0
shirkevich/docker-ipsec            forked from cpuguy83/docker-ipsec               0
ibotty/ipsec-libreswan             minimal priviliged ipsec container for use...   0                    [OK]
kiwenlau/ipsec                                                                     0
mhoger/ipsec-vpn                                                                   0
ciscolabs/ipsec-cpe                                                                0
jaredmichaelsmith/mds-ipsec                                                        0
plitc/easy_ipsec                   easy_ipsec                                      0                    [OK]
furaoing/ipsec-xl2tpd                                                              0
ciscolabs/ipsec

# 选择STARS最多的镜像，或自行参考[作者Github](https://github.com/hwdsl2/docker-ipsec-vpn-server)

$ sudo docker pull hwdsl2/ipsec-vpn-server

$ sudo mkdir /usr/local/ipsec

# 自行修改环境变量..

$ sudo vim /usr/local/ipsec/ipsec.env

VPN_IPSEC_PSK=<IPsec pre-shared key>
VPN_USER=<VPN Username>
VPN_PASSWORD=<VPN Password>

$ sudo modprobe af_key

# 启动docker镜像

$ docker run --name ipsec-vpn-server --env-file /usr/local/ipsec/ipsec.env -p 500:500/udp -p 4500:4500/udp -v /lib/modules:/lib/modules:ro -d --privileged hwdsl2/ipsec-vpn-server

# 自行审阅docker日志..

$ docker logs ipsec-vpn-server

# 检查docker镜像ipsec服务的运行情况

$ docker exec -it ipsec-vpn-server ipsec status

~~~

OK，至此大功告成，VPN in Vultr VPS已经安装成功。

Shadowsocks的客户端配置很简单，IPsec记得需要填写两个密码，如上环境变量的KEY-VALUE，一个是VPN_PASSWORD的值，另一个是VPN_IPSEC_PSK的值，还是比较简单的，就不贴图了..


**言而总之，本文推荐docker安装shadowsocks和IPsec，简单可控，统一管理~~**


### 国际惯例：

同学们如有VPN的需求，请参考上述教程，鉴于我目前在用Vultr，贴个邀请码吧，请从以下链接点击注册：

- 2016年夏季促销：

  [Summer Promo Code](http://www.vultr.com/?ref=6953793-3B): *http://www.vultr.com/?ref=6953793-3B*
  
  For a Limited Time - Give $20, Get $30!
  
  * Every user referred with this link will get $20 to use the Vultr platform and you will receive $30!
  
  * Referred users must be active for 30+ days and use at least $10 in payments to be counted as verified sales.
  
  * Payouts are finalized and issued on the business day following the 1st and 15th of each month.
  
  * Please Note! This code will revert to our default program at the end of the promotion.

- 长期有效：

  [Linking Code](http://www.vultr.com/?ref=6953792): *http://www.vultr.com/?ref=6953792*
  
  Refer Vultr.com and earn $10 per paid signup!
  
  * $10 earned for every new unique paid user you refer.
  
  * Referred users must be active for 30+ days and use at least $10 in payments to be counted as verified sales.
  
  * Payouts are finalized and issued on the business day following the 1st and 15th of each month.
  
  * Your referral link below uniquely identifies your account. Use this code when linking to Vultr.com and start earning today!

顺带吐槽，Vultr的优惠政策略坑爹，且不注明：

优惠政策只能同时生效一种，如果已经应用过优惠码，则其它优惠不叠加，而且充值的赠送$5也不会再入账，虽然页面上仍有提示赠送..


{% include references.md %}