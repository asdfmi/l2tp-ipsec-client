# l2tp-ipsec-client

A single-script L2TP/IPsec VPN client for Linux.

## Prerequisites

```bash
sudo apt update
sudo apt install strongswan xl2tpd ppp
```

## Setup

```bash
cp .env.example .env
# Edit .env with your values
chmod +x lic.sh
```

## Usage

```bash
./lic.sh up
./lic.sh down
./lic.sh status
```

`up` generates config files and establishes the connection with split-tunnel routing.  
`down` tears down the connection and removes all generated config files.
