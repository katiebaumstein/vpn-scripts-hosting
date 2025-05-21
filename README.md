# VPN Scripts Hosting

A simple Node.js Express server for hosting VPN installation scripts. Users can install VPN servers using a single curl command.

## Available Scripts

- `hysteria2_debian12.sh` - Hysteria2 VPN server for Debian 12
- `snell_debian12.sh` - Snell proxy server for Debian 12
- `vlessvr_debian12.sh` - VLESS+Reality protocol server for Debian 12

## Project Structure

```
vpn-scripts-hosting/
├── public/              # Static web files
│   └── index.html       # Landing page
├── scripts/             # Original VPN installation scripts
│   ├── hysteria2_debian12.sh
│   ├── snell_debian12.sh
│   └── vlessvr_debian12.sh
├── scripts-normalized/  # Normalized scripts (generated)
├── utils/               # Utility scripts
│   └── normalize.js     # Script to normalize special characters
├── server.js            # Express server
├── package.json         # Node.js project configuration
└── README.md            # This documentation
```

## Special Character Handling

The scripts include Unicode box-drawing characters that may display incorrectly in some environments. The server handles this in two ways:

1. **On-the-fly normalization**: When scripts are served, Unicode characters are automatically converted to ASCII alternatives (e.g., "â"€" becomes "-").

2. **Pre-normalized scripts**: You can also generate normalized versions of all scripts by running:
   ```bash
   npm run normalize
   ```
   This creates ASCII-only versions in the `scripts-normalized/` directory.

## Script Access Methods

There are multiple ways to access the scripts:

1. **Direct execution with curl/wget**: 
   ```bash
   curl -fsSL https://your-domain.com/hysteria2_debian12.sh | sudo bash
   ```
   The server automatically serves the script as a downloadable file when requested with curl/wget.

2. **Download via browser**: 
   ```
   https://your-domain.com/hysteria2_debian12.sh
   ```
   In a browser, you can click the "Download Script" button or visit the script URL with the download attribute.

3. **View script content**: 
   ```
   https://your-domain.com/raw/hysteria2_debian12.sh
   ```
   The `/raw/` prefix displays the script content in the browser for inspection.

## Local Setup

1. Install dependencies (one-time setup):
   ```bash
   npm install express
   ```

2. Start the server:
   ```bash
   npm start
   ```

3. Access the website at `http://localhost:3000`

## Deployment to AWS

### Prerequisites
- AWS EC2 instance running Amazon Linux, Ubuntu, or Debian
- Node.js installed on the server
- Domain name pointing to your server (optional but recommended)

### Deployment Steps

1. Clone the repository on your AWS instance:
   ```bash
   git clone https://github.com/yourusername/vpn-scripts-hosting.git
   cd vpn-scripts-hosting
   ```

2. Install dependencies:
   ```bash
   npm install express
   ```

3. Start the server with PM2 (recommended for production):
   ```bash
   # Install PM2 if not already installed
   npm install -g pm2
   
   # Start the server with PM2
   pm2 start server.js
   
   # Ensure PM2 starts on system boot
   pm2 startup
   pm2 save
   ```

4. Configure a reverse proxy with Nginx (optional but recommended):
   ```bash
   # Install Nginx
   sudo apt update
   sudo apt install nginx
   
   # Create Nginx configuration
   sudo nano /etc/nginx/sites-available/vpn-scripts
   ```

   Add this configuration:
   ```nginx
   server {
       listen 80;
       server_name your-domain.com; # Replace with your domain

       location / {
           proxy_pass http://localhost:3000;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection 'upgrade';
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_cache_bypass $http_upgrade;
       }
   }
   ```

   Enable the configuration:
   ```bash
   sudo ln -s /etc/nginx/sites-available/vpn-scripts /etc/nginx/sites-enabled/
   sudo nginx -t
   sudo systemctl restart nginx
   ```

5. Set up SSL with Certbot (optional but recommended):
   ```bash
   sudo apt install certbot python3-certbot-nginx
   sudo certbot --nginx -d your-domain.com
   ```

## Usage

Once deployed, users can install VPN servers using:

```bash
curl -fsSL https://your-domain.com/hysteria2_debian12.sh | sudo bash
curl -fsSL https://your-domain.com/snell_debian12.sh | sudo bash
curl -fsSL https://your-domain.com/vlessvr_debian12.sh | sudo bash
```

They can also visit the website at `https://your-domain.com` to see all available scripts.