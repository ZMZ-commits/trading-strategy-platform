# Putting dev, staging and the IDE behind a login

Today these four hostnames resolve straight to the VM and answer anyone:

```
api.zemingzhang.com       37.27.41.226   grey cloud   public, no auth
api-stg.zemingzhang.com   37.27.41.226   grey cloud   public, no auth
api-dev.zemingzhang.com   37.27.41.226   grey cloud   public, no auth
ide.zemingzhang.com       37.27.41.226   grey cloud   one password
```

`GET /strategies` on dev and staging returns data to anyone who asks. CORS does
not prevent this — it is a browser convention, and `curl` ignores it.

**`ide.zemingzhang.com` is the urgent one.** It is a browser shell with arbitrary
code execution, on the same machine as the production API, protected by a single
password. Everything else here is a data leak; that one is a foothold.

**The goal:** prod stays public, the other three require a Google login, and
nothing new is installed anywhere.

---

## Why Cloudflare Access and not Tailscale

Tailscale is the better answer for *network* access — SSH, `kubectl`, Terraform
from CI. It is the wrong shape for web apps, because a hostname pointing at a
private address has to solve DNS and TLS certificates before a browser will load
it.

Access sits in front of the hostname you already have. No client software, no
DNS tricks, no certificate work, and it works from a phone.

Use Tailscale for the CI-and-SSH problem. That is a separate piece of work and
neither depends on the other.

---

## 1 — Check the TLS mode first

**This is the step that breaks everything if skipped.**

Cloudflare dashboard → your domain → **SSL/TLS** → Overview.

It must be **Full (strict)** or **Full**. If it says **Flexible**, Cloudflare
will connect to Caddy over plain HTTP, Caddy will redirect to HTTPS, Cloudflare
will follow it back to itself, and the site will fail with `ERR_TOO_MANY_REDIRECTS`
the instant you turn the proxy on.

Caddy already holds real Let's Encrypt certificates, so **Full (strict)** is
correct.

---

## 2 — Proxy the three non-prod hostnames

Cloudflare dashboard → **DNS** → Records.

For `api-dev`, `api-stg` and `ide`: click the grey cloud so it turns **orange**.

**Leave `api` alone for now.** Production keeps working exactly as it does while
you prove this out on the environments that can afford to break.

Wait a minute, then confirm the change took:

```bash
nslookup api-dev.zemingzhang.com
```

It should now answer with a Cloudflare address (`104.x` or `172.67.x`), not
`37.27.41.226`.

Then load `https://api-dev.zemingzhang.com/strategies` in a browser. **It should
still work, and still be public** — you have only changed the path, not the
access rules. If it errors here, fix that before continuing; Access will only
make it harder to debug.

---

## 3 — Turn on Zero Trust

Cloudflare dashboard → **Zero Trust**.

First run asks for a team name — it becomes `<team>.cloudflareaccess.com` and
shows up on the login page. Choose the **Free** plan.

Free covers 50 users. A user is a human identity that authenticates, held until
removed. You are one.

---

## 4 — Add the application

**Zero Trust → Access → Applications → Add an application → Self-hosted**

| Field | Value |
|---|---|
| Application name | `tsp-non-prod` |
| Session duration | 24 hours |

Add three domains to the same application:

```
api-dev.zemingzhang.com
api-stg.zemingzhang.com
ide.zemingzhang.com
```

One application covering three hostnames means one policy to maintain and one
login for all of them.

---

## 5 — The policy

| Field | Value |
|---|---|
| Policy name | `operator` |
| Action | **Allow** |
| Include | **Emails** → `zhang.zeming.zz@gmail.com` |

`Emails` with the built-in one-time-PIN login needs no identity provider setup —
Cloudflare emails you a code. If you would rather click "Sign in with Google",
add Google as an identity provider under **Settings → Authentication** first.

---

## 6 — Test it properly

**In your normal browser:**

```
https://api-dev.zemingzhang.com/strategies
```

You should be redirected to a Cloudflare login page, and reach the data after
authenticating.

**Now the test that actually matters — in a private window:**

```
https://api-dev.zemingzhang.com/strategies
```

You should get the login page and **no data**. If you see strategies, the policy
is not applied to that hostname and you should stop and check step 4.

**And confirm prod is untouched:**

```
https://api.zemingzhang.com/strategies
```

Still public, no login. That is correct — it has no Access policy.

---

## 7 — Close the bypass

At this point Access protects the *Cloudflare* path. But the origin is still
listening on `37.27.41.226:443`, and anyone who knows that address can send a
request with a `Host: api-dev.zemingzhang.com` header and **walk straight past
Access**.

The origin IP is not secret. It was in public DNS until step 2, and it is in
certificate-transparency logs.

So the origin must stop accepting connections from anywhere but Cloudflare.

**First, proxy `api` too** — orange cloud, same as step 2 — or the next change
takes production down. Verify prod still loads before continuing.

Then restrict the firewall. Cloudflare publishes 15 IPv4 and 7 IPv6 ranges — 22
total, which fits comfortably in one Hetzner rule (the limit is 100 source IPs
per rule; for comparison, allow-listing GitHub Actions would have needed 6,980).

```bash
curl -s https://www.cloudflare.com/ips-v4
curl -s https://www.cloudflare.com/ips-v6
```

Hetzner console → Firewalls → the firewall on `trading-platform` → the rule for
ports 80 and 443 → replace `0.0.0.0/0` with those ranges.

**`trading-platform` is not managed by Terraform** — it predates this stack and
is not in `agent_roles`. So this is a console change, not a `terraform apply`.

**Verify the bypass is actually closed:**

```bash
curl -sI --max-time 10 --resolve api-dev.zemingzhang.com:443:37.27.41.226 \
  https://api-dev.zemingzhang.com/strategies
```

That forces a connection to the origin IP while sending the real hostname —
exactly what an attacker would do. It should **time out**. If it returns `200`,
the firewall rule has not taken effect and Access is still bypassable.

---

## What to watch for afterwards

**The UI calling the API cross-origin.** `trading-dev.zemingzhang.com` (Pages)
makes XHR calls to `api-dev.zemingzhang.com` (now behind Access). The browser
must send the `CF_Authorization` cookie with those requests, which needs CORS
configured for credentials on both sides. **Test the dev UI end to end after
step 6** — if charts stop loading, this is why, and the fix is putting the Pages
hostnames behind the same Access application so one login covers both.

**WebSockets.** `/ws/live/{ticker}` goes through Cloudflare's proxy now.
Cloudflare handles WebSockets, but it is worth confirming the live tick feed
still streams rather than assuming.

**Certificate renewal.** Caddy renews via Let's Encrypt HTTP-01, which now
passes through Cloudflare. It normally works, but the first renewal after this
change is worth watching — a failure there is silent until the certificate
expires.

---

## What this does not cover

SSH, `kubectl`, and Terraform from CI. Those need network access rather than a
web login, and Tailscale is the right tool. Separate piece of work, no dependency
in either direction.
