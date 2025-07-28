#!/bin/bash
set -e

PANEL_DIR="/var/www/html/vpn-visit-panel"

echo "=== [1] Kill Node/OpenVPN and Purge All Ubuntu Node.js/Dev Libs ==="
sudo pkill -9 node || true
sudo pkill -9 npm || true
sudo pkill -9 openvpn || true
sudo apt remove --purge -y nodejs npm libnode-dev nodejs-doc || true
sudo dpkg --purge nodejs npm libnode-dev nodejs-doc || true
sudo apt autoremove -y
sudo apt clean
sudo rm -rf /usr/include/node /usr/lib/node_modules /usr/local/bin/node* /usr/local/bin/npm* /usr/local/lib/node* /usr/share/doc/nodejs
sudo rm -rf /var/lib/dpkg/info/nodejs* /var/lib/dpkg/info/libnode-dev*
sudo dpkg --configure -a
sudo apt -f install -y

echo "=== [2] Hold Ubuntu's libnode-dev forever ==="
sudo apt-mark hold libnode-dev

echo "=== [3] Install Node.js v18 from NodeSource only ==="
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt update
sudo apt install -y nodejs

echo "=== [4] Install other dependencies ==="
sudo apt install -y openvpn apache2 php php-cli php-zip curl git

echo "=== [5] Create panel directory ==="
sudo mkdir -p "$PANEL_DIR"
sudo chown $USER:$USER "$PANEL_DIR"
cd "$PANEL_DIR"

echo "=== [6] Write admin.php ==="
cat > admin.php <<'EOF'
<?php
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!file_exists('vpn_configs')) mkdir('vpn_configs', 0777, true);
    foreach ($_FILES['ovpn_files']['tmp_name'] as $i => $tmp) {
        if ($_FILES['ovpn_files']['name'][$i])
            move_uploaded_file($tmp, 'vpn_configs/' . basename($_FILES['ovpn_files']['name'][$i]));
    }
    file_put_contents("settings.json", json_encode([
        "username" => $_POST['username'],
        "password" => $_POST['password'],
        "url" => $_POST['url'],
        "visits" => (int)$_POST['visits']
    ]));
    shell_exec("pkill openvpn");
    shell_exec("pkill node");
    file_put_contents("visit.log", "");
    shell_exec("nohup php start.php > /dev/null 2>&1 &");
    header("Location: admin.php?started=1");
    exit;
}
?>
<!DOCTYPE html>
<html>
<head>
    <title>VPN Auto Visit Panel</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css">
    <script>
    window.onload = function() {
        function updateLog() {
            fetch('visit.log?'+Math.random()).then(res=>res.text()).then(txt=>{
                document.getElementById('progress_log').innerText = txt;
            });
        }
        updateLog();
        setInterval(updateLog, 5000);
    }
    </script>
</head>
<body class="container mt-4">
    <h2>VPN Auto Visit Panel</h2>
    <form method="POST" enctype="multipart/form-data" class="mb-4">
        <div class="mb-2">
            <label>Upload OVPN Configs (multiple):</label>
            <input type="file" name="ovpn_files[]" multiple required>
        </div>
        <div class="mb-2">
            <label>OpenVPN Username:</label>
            <input type="text" name="username" required>
        </div>
        <div class="mb-2">
            <label>OpenVPN Password:</label>
            <input type="password" name="password" required>
        </div>
        <div class="mb-2">
            <label>Target URL:</label>
            <input type="url" name="url" required>
        </div>
        <div class="mb-2">
            <label>Visits to Perform:</label>
            <input type="number" name="visits" min="1" value="10" required>
        </div>
        <button class="btn btn-primary">Start Visits</button>
    </form>
    <h4>Progress</h4>
    <pre id="progress_log" style="background:#eee;padding:1em;max-height:300px;overflow:auto;"></pre>
</body>
</html>
EOF

echo "=== [7] Write start.php ==="
cat > start.php <<'EOF'
<?php
$settings = json_decode(file_get_contents('settings.json'), true);
$configs = glob(__DIR__."/vpn_configs/*.ovpn");
for ($i = 0; $i < $settings['visits']; $i++) {
    $cfg = $configs[$i % count($configs)];
    $cmd = "bash run_visit.sh '" . addslashes($cfg) . "' '" . addslashes($settings['username']) . "' '" . addslashes($settings['password']) . "' '" . addslashes($settings['url']) . "'";
    file_put_contents("visit.log", date("Y-m-d H:i:s")." | Starting visit ".($i+1)."/".$settings['visits']."\n", FILE_APPEND);
    shell_exec($cmd);
}
?>
EOF

echo "=== [8] Write run_visit.sh ==="
cat > run_visit.sh <<'EOF'
#!/bin/bash
CONFIG="$1"
USERNAME="$2"
PASSWORD="$3"
URL="$4"
LOG="visit.log"

TMPPASS=$(mktemp)
echo -e "$USERNAME\n$PASSWORD" > $TMPPASS

echo "$(date) | Connecting VPN: $CONFIG" >> $LOG

sudo openvpn --config "$CONFIG" --auth-user-pass $TMPPASS --daemon
sleep 12

IP=$(curl -s ifconfig.me)
COUNTRY=$(curl -s ipinfo.io/$IP/country)

if [ -z "$IP" ]; then
    echo "$(date) | Failed to get IP, skipping..." >> $LOG
    sudo pkill openvpn
    rm $TMPPASS
    exit 1
fi

echo "$(date) | Connected as $IP ($COUNTRY)" >> $LOG

node puppeteer_visit.js "$URL" >> $LOG 2>&1

echo "$(date) | Disconnecting VPN" >> $LOG
sudo pkill openvpn
rm $TMPPASS
sleep 5
EOF

chmod +x run_visit.sh

echo "=== [9] Write puppeteer_visit.js ==="
cat > puppeteer_visit.js <<'EOF'
const puppeteer = require('puppeteer');
(async () => {
    const url = process.argv[2];
    if (!url) process.exit(1);

    // Try default path first, else fallback to system Chromium if installed
    let launchOpts = { headless: true, args: ['--no-sandbox'] };
    const fs = require('fs');
    if (fs.existsSync('/usr/bin/chromium-browser')) {
        launchOpts.executablePath = '/usr/bin/chromium-browser';
    }
    const browser = await puppeteer.launch(launchOpts);
    const page = await browser.newPage();
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 60000 });
    await page.waitForTimeout(10000);
    const elements = await page.$$('*');
    if (elements.length) {
        const randIdx = Math.floor(Math.random() * elements.length);
        await elements[randIdx].click().catch(()=>{});
    }
    await page.waitForTimeout(20000);
    await browser.close();
    console.log(new Date().toISOString() + " | Visited " + url + " and clicked.");
})();
EOF

echo "=== [10] Create configs, permissions ==="
mkdir -p vpn_configs
touch visit.log
touch settings.json
sudo chown -R www-data:www-data "$PANEL_DIR"
chmod -R 755 "$PANEL_DIR"

echo "=== [11] Install puppeteer (node module) and download Chromium ==="
npm install puppeteer --force
npx puppeteer browsers install chrome || true

# Optionally install system Chromium for fallback
sudo apt install -y chromium-browser || true

echo "=== [12] Start apache2 ==="
sudo systemctl start apache2

echo
echo "=== ALL DONE! ==="
echo "Go to: http://<YOUR-VPS-IP>/vpn-visit-panel/admin.php"
echo "Upload .ovpn files, fill the form, and GO!"
echo
