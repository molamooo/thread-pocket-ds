# 对外部署示例

目标形态：Thread Pocket 只监听本机，由反向代理对外提供 HTTPS。
这样 TLS、域名、证书都由代理负责，应用侧只需要声明自己的对外地址。

```bash
THREADPOCKET_PUBLIC_URL=https://pocket.example.com \
HOST=127.0.0.1 PORT=8787 \
THREADPOCKET_DB=/var/lib/thread-pocket/data.sqlite \
node src/index.js
```

## Caddy

Caddy 自动申请并续期证书，是最省事的选择。

```caddyfile
pocket.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8787 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
```

## nginx

```nginx
server {
    listen 443 ssl http2;
    server_name pocket.example.com;

    ssl_certificate     /etc/letsencrypt/live/pocket.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pocket.example.com/privkey.pem;

    client_max_body_size 4m;

    location / {
        proxy_pass http://127.0.0.1:8787;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $remote_addr;

        # MCP 是短请求，不需要长连接；如果以后加入 SSE，再放开缓冲设置
        proxy_buffering off;
        proxy_read_timeout 90s;
    }
}
```

## Cloudflare Tunnel（没有公网 IP 时）

```bash
cloudflared tunnel --url http://127.0.0.1:8787
# 拿到形如 https://xxx.trycloudflare.com 的地址后：
THREADPOCKET_PUBLIC_URL=https://xxx.trycloudflare.com node src/index.js
```

## systemd

```ini
[Unit]
Description=Thread Pocket API
After=network.target

[Service]
WorkingDirectory=/opt/thread-pocket/server
Environment=HOST=127.0.0.1
Environment=PORT=8787
Environment=THREADPOCKET_PUBLIC_URL=https://pocket.example.com
Environment=THREADPOCKET_DB=/var/lib/thread-pocket/data.sqlite
ExecStart=/usr/bin/node src/index.js
Restart=always

[Install]
WantedBy=multi-user.target
```

## 部署后的自检

```bash
BASE=https://pocket.example.com

# 1. 元信息里的地址应当是公网域名
curl -s $BASE/.well-known/oauth-authorization-server | jq .issuer
curl -s $BASE/.well-known/oauth-protected-resource/mcp | jq .resource

# 2. 匿名访问必须被拒绝，并且带上可发现的挑战
curl -s -i $BASE/api/v1/snapshot | grep -i '^HTTP\|www-authenticate'

# 3. MCP 也必须要求令牌
curl -s -i -X POST $BASE/mcp -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | head -3
```

三条都符合预期后，再用桌面端登录一次、让一个 MCP 客户端连一次，
最后回到 `/auth/connections` 确认授权列表里只有你认识的客户端。
