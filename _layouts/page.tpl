<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="author" content="{{ site.meta.author.name }}" />
<meta name="keywords" content="{{ page.tags | join: ',' }}" />
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>{{ site.name }}{% if page.title %} / {{ page.title }}{% endif %}</title>
<link href="http://{{ site.host }}/feed.xml" rel="alternate" title="{{ site.name }}" type="application/atom+xml" />
<link rel="stylesheet" href="/lib/font-awesome-4.5.0/css/font-awesome.min.css" />
<link rel="stylesheet" type="text/css" href="/assets/css/site.css" />
<link rel="stylesheet" type="text/css" href="/assets/css/code/github.css" />
<link rel="icon" href="/images/favicon.png" type="image/x-icon" />
<link rel="shortcut icon" href="/images/favicon.png" type="image/x-icon" />
{% for style in page.styles %}<link rel="stylesheet" type="text/css" href="{{ style }}" />
{% endfor %}
<script>
  (function(i,s,o,g,r,a,m){i['GoogleAnalyticsObject']=r;i[r]=i[r]||function(){
  (i[r].q=i[r].q||[]).push(arguments)},i[r].l=1*new Date();a=s.createElement(o),
  m=s.getElementsByTagName(o)[0];a.async=1;a.src=g;m.parentNode.insertBefore(a,m)
  })(window,document,'script','https://www.google-analytics.com/analytics.js','ga');

  ga('create', '{{ site.meta.author.analytics }}', 'auto');
  ga('send', 'pageview');
</script>
</head>

<body class="{{ layout.class }}">

<div class="main">
    {{ content }}

    <footer>
        <p>&copy; Since 2016 by {{ site.meta.author.name }}</p>
    </footer>
</div>

<aside>
    <img align="middle" src="/images/dog.jpg" alt="dog">
    <h2>
    <a href="/">{{ site.name }}</a>
    <a href="/feed.xml" class="feed-link" title="Subscribe"><i class="fa fa-rss-square"></i></a>
    <a href="{{ site.meta.author.weibo }}" title="Weibo"><i class="fa fa-weibo" aria-hidden="true"></i></a>
    <a href="https://github.com/{{ site.meta.author.github }}" title="GitHub"><i class="fa fa-github-square" style="color:black"></i></a>
    </h2>

    <nav class="block">
        <ul>
        {% for category in site.custom.categories %}<li class="{{ category.name }}"><a href="/category/{{ category.name }}/">{{ category.title }}</a></li>
        {% endfor %}
        </ul>
    </nav>

    <form action="/search/" class="block block-search">
        <h3>Search</h3>
        <p><input type="search" name="q" placeholder="Search" /></p>
    </form>

    <div class="block block-about">
        <h3>About</h3>
        <figure>
            {% if site.meta.author.gravatar %}<img src="{{ site.meta.gravatar}}{{ site.meta.author.gravatar }}?s=48" />{% endif %}
            <figcaption><strong>{{ site.meta.author.name }}</strong></figcaption>
        </figure>
        {% if site.meta.author.desc %}
        <p>{{ site.meta.author.desc }}</p>
        {% endif %}
    </div>

    <div class="block block-license">
        <h3>Copyright</h3>
        <p><a rel="license" href="http://creativecommons.org/licenses/by-nc-nd/2.5/cn/" target="_blank" class="hide-target-icon" title="Copyright declaration of site content"><img alt="知识共享许可协议" src="/images/copyright.png" /></a></p>
    </div>

    <div class="block block-thank">
        <h3>Powered by</h3>
        <p>
            <a href="http://disqus.com/" target="_blank">Disqus</a>,
            <a href="http://elfjs.com/" target="_blank">elf+js</a>,
            <a href="https://github.com/" target="_blank">GitHub</a>,
            <a href="http://www.google.com/cse/" target="_blank">Google Custom Search</a>,
            <a href="http://en.gravatar.com/" target="_blank">Gravatar</a>,
            <a href="http://softwaremaniacs.org/soft/highlight/en/">HighlightJS</a>,
            <a href="https://github.com/mojombo/jekyll" target="_blank">jekyll</a>,
            <a href="https://github.com/mytharcher/SimpleGray" target="_blank">SimpleGray</a>
        </p>
    </div>
</aside>

<script src="/assets/js/elf-0.5.0.min.js"></script>
<script src="/assets/js/highlight.min.js"></script>

<script src="/assets/js/site.js"></script>
{% for script in page.scripts %}<script src="{{ script }}"></script>
{% endfor %}
<script>
site.URL_GOOGLE_API = '{{site.meta.gapi}}';
site.URL_DISCUS_COMMENT = '{{ site.meta.author.disqus }}' ? 'http://{{ site.meta.author.disqus }}.{{ site.meta.disqus }}' : '';

site.VAR_SITE_NAME = "{{ site.name | replace:'"','\"' }}";
site.VAR_GOOGLE_CUSTOM_SEARCH_ID = '{{ site.meta.author.gcse }}';
site.TPL_SEARCH_TITLE = '#{0} / 搜索：#{1}';
site.VAR_AUTO_LOAD_ON_SCROLL = {{ site.custom.scrollingLoadCount }};
</script>
</body>
</html>
