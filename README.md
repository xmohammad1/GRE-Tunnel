# gre-manager

مدیریت تانل GRE بین سرور ایران و سرورهای خارج — با پشتیبانی از **یک سرور ایران به چند سرور خارج**.

## امکانات

- **چند تانل روی یک سرور**: هر تانل یک نام و یک ID (۱ تا ۲۵۴) دارد و ساب‌نت آن خودکار تعیین می‌شود: `10.100.<ID>.0/30` (ایران `.1`، خارج `.2`)
- **پایدار بعد از ریبوت** با سرویس systemd قالبی `gre-manager@<name>`
- **Port forwarding** از سرور ایران به سرور خارج (DNAT + SNAT)، با تشخیص تداخل پورت‌ها بین تانل‌ها و جلوگیری از فوروارد کردن پورت SSH
- **MSS clamping** برای جلوگیری از مشکلات MTU (فعال به‌صورت پیش‌فرض)
- **IPv6 داخل تانل** (اختیاری، `fd10:100:<ID>::/64`)
- **NAT-out** روی سرور خارج تا سرور ایران بتواند از آن به‌عنوان گیت‌وی اینترنت استفاده کند
- **مانیتور سلامت**: هر یک دقیقه تانل‌ها پینگ می‌شوند و تانل قطع‌شده بعد از ۳ خطای پشت سر هم ری‌استارت می‌شود
- **تست اتصال**: latency، packet loss و کشف Path MTU با پیشنهاد مقدار MTU مناسب
- **بهینه‌سازی کرنل**: BBR + fq، ip_forward، rp_filter حالت loose، بافرهای TCP بزرگ‌تر
- **بکاپ و ریستور** تنظیمات
- **انتقال از اسکریپت قدیمی** (`gre2manager.sh` / تانل `tun2`) با حفظ آدرس‌های `20.0.0.x`
- منوی تعاملی + **CLI کامل** برای اتوماسیون، لاگ در `/var/log/gre-manager.log`

## نصب

```bash
sudo bash gre-manager.sh
```

اولین اجرا اسکریپت را در `/usr/local/bin/gre-manager` نصب می‌کند؛ از آن به بعد کافی است `sudo gre-manager` بزنید.
نیازمندی‌ها (iproute2، iptables، ping، curl) در صورت نبودن خودکار نصب می‌شوند. سیستم باید systemd داشته باشد و کرنل از GRE پشتیبانی کند (روی OpenVZ/LXC معمولاً کار نمی‌کند).

## مثال: یک سرور ایران و دو سرور خارج

روی سرور **ایران**:

```bash
gre-manager add --role iran --id 1 --remote 203.0.113.10 --forward "tcp:443"
gre-manager add --role iran --id 2 --remote 198.51.100.20 --forward "tcp:8443>443 udp:51820"
```

روی سرور **خارج ۱** و **خارج ۲** (بعد از هر `add`، دستور دقیقِ سمت مقابل چاپ می‌شود):

```bash
gre-manager add --role kharej --id 1 --remote <IP-ایران>
gre-manager add --role kharej --id 2 --remote <IP-ایران>
```

> **ID تانل باید در دو طرف یکسان باشد.** اگر بین دو سرور یکسان بیش از یک تانل لازم دارید، با `--key` یک GRE key متفاوت بدهید.

## فرمت قوانین Port forwarding

```text
proto:port[-port][>target_port]      proto = tcp | udp | both
```

| قانون | معنی |
|---|---|
| `tcp:443` | پورت 443 ایران ← پورت 443 خارج |
| `both:8443` | TCP و UDP روی 8443 |
| `tcp:2000-2100` | یک بازه پورت |
| `tcp:2222>22` | پورت 2222 ایران ← پورت 22 خارج |

## دستورات

| دستور | کار |
|---|---|
| `gre-manager` | منوی تعاملی |
| `gre-manager list` | لیست تانل‌ها با وضعیت و latency |
| `gre-manager status [name]` | جزئیات تانل (ترافیک، سرویس، فورواردها) |
| `gre-manager test <name>` | تست پینگ، packet loss و MTU |
| `gre-manager restart <name\|--all>` | ری‌استارت تانل |
| `gre-manager remove <name\|--all>` | حذف تانل |
| `gre-manager forward <name> list\|add\|del\|clear` | مدیریت فورواردها بدون قطع تانل |
| `gre-manager monitor [--enable\|--disable]` | مانیتور سلامت |
| `gre-manager optimize` | بهینه‌سازی کرنل (BBR) |
| `gre-manager backup` / `restore <file>` | بکاپ و ریستور |
| `gre-manager import-legacy` | انتقال تانل اسکریپت قدیمی |
| `gre-manager uninstall [--purge]` | حذف کامل |

همه گزینه‌های `add` با `gre-manager help` نمایش داده می‌شوند.

## فایل‌ها

| مسیر | محتوا |
|---|---|
| `/etc/gre-manager/tunnels/<name>.conf` | تنظیمات هر تانل |
| `/etc/gre-manager/gre-manager.conf` | تنظیمات عمومی (ساب‌نت پایه، MTU پیش‌فرض، مانیتور) |
| `/etc/systemd/system/gre-manager@.service` | سرویس قالبی تانل‌ها |
| `/etc/systemd/system/gre-manager-monitor.timer` | تایمر مانیتور سلامت |
| `/root/gre-manager-backups/` | بکاپ‌ها |
| `/var/log/gre-manager.log` | لاگ |

قوانین فایروال هر تانل در chainهای جداگانه `GREM-<name>-*` قرار می‌گیرند، پس با قوانین دیگر (ufw، docker و...) تداخل ندارند و با حذف تانل کاملاً پاک می‌شوند.
