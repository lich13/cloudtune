// Release signing helper. Private key material stays outside the repository (~/.config/cloudtune/android-signing, 0600) and is never printed.
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const repoSlug = process.env.CLOUDTUNE_GITHUB_REPO || "lich13/cloudtune";
const directory = process.env.CLOUDTUNE_SIGNING_DIR || join(homedir(), ".config", "cloudtune", "android-signing");
const properties = join(directory, "release.properties");
const keystore = join(directory, "release.p12");
const keyAlias = "cloudtune-release";

function resolveKeytool() {
  if (process.platform === "darwin") {
    if (!existsSync("/usr/libexec/java_home")) return null;
    const probe = spawnSync("/usr/libexec/java_home", [], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    if (probe.status !== 0) return null;
    const javaHome = (probe.stdout || "").trim();
    if (!javaHome) return null;
    const candidate = join(javaHome, "bin", "keytool");
    return existsSync(candidate) ? candidate : null;
  }
  const which = spawnSync("which", ["keytool"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  if (which.status !== 0) return null;
  const candidate = (which.stdout || "").trim();
  return candidate && existsSync(candidate) ? candidate : null;
}

function resolveOpenSsl3Or4() {
  const candidates = [
    process.env.OPENSSL_BIN,
    "/opt/homebrew/bin/openssl",
    "/usr/local/bin/openssl",
  ].filter(Boolean);

  for (const bin of candidates) {
    if (!existsSync(bin)) continue;
    const ver = spawnSync(bin, ["version"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    const out = (ver.stdout || "").trim();
    if (ver.status === 0 && /^OpenSSL [34]\./.test(out)) {
      return bin;
    }
  }
  throw new Error(
    "Neither a valid JDK keytool nor OpenSSL 3.x/4.x (/opt/homebrew/bin/openssl or /usr/local/bin/openssl) is available; refusing to invoke LibreSSL"
  );
}

function generatePkcs12WithKeytool(keytoolBin, password) {
  const result = spawnSync(
    keytoolBin,
    [
      "-genkeypair",
      "-keystore", keystore,
      "-storetype", "PKCS12",
      "-storepass:env", "CLOUDTUNE_SIGNING_PASSWORD",
      "-keypass:env", "CLOUDTUNE_SIGNING_PASSWORD",
      "-alias", keyAlias,
      "-keyalg", "RSA",
      "-keysize", "3072",
      "-validity", "10000",
      "-dname", "CN=CloudTune, O=lich13",
    ],
    {
      env: { ...process.env, CLOUDTUNE_SIGNING_PASSWORD: password },
      stdio: "pipe",
    }
  );
  if (result.status !== 0) {
    throw new Error("keytool PKCS#12 release signing key creation failed");
  }
}

function generatePkcs12WithOpenSsl(opensslBin, password) {
  const scratch = mkdtempSync(join(tmpdir(), "cloudtune-p12-"));
  chmodSync(scratch, 0o700);
  const keyPem = join(scratch, "key.pem");
  const certPem = join(scratch, "cert.pem");
  try {
    const reqRes = spawnSync(
      opensslBin,
      [
        "req",
        "-x509",
        "-newkey", "rsa:3072",
        "-sha256",
        "-days", "10000",
        "-nodes",
        "-subj", "/CN=CloudTune/O=lich13",
        "-keyout", keyPem,
        "-out", certPem,
      ],
      { stdio: "pipe" }
    );
    if (reqRes.status !== 0) {
      throw new Error("OpenSSL X.509 certificate generation failed");
    }

    const p12Res = spawnSync(
      opensslBin,
      [
        "pkcs12",
        "-export",
        "-in", certPem,
        "-inkey", keyPem,
        "-name", keyAlias,
        "-keypbe", "AES-256-CBC",
        "-certpbe", "AES-256-CBC",
        "-macalg", "sha256",
        "-out", keystore,
        "-passout", "env:CLOUDTUNE_SIGNING_PASSWORD",
      ],
      {
        env: { ...process.env, CLOUDTUNE_SIGNING_PASSWORD: password },
        stdio: "pipe",
      }
    );
    if (p12Res.status !== 0) {
      throw new Error("OpenSSL PKCS#12 export failed");
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

mkdirSync(directory, { recursive: true, mode: 0o700 });
chmodSync(directory, 0o700);

if (!existsSync(properties)) {
  if (existsSync(keystore)) {
    throw new Error("Existing signing keystore has no release.properties; refusing to overwrite it");
  }
  const password = randomBytes(32).toString("hex");
  const keytoolBin = resolveKeytool();
  if (keytoolBin) {
    generatePkcs12WithKeytool(keytoolBin, password);
  } else {
    const opensslBin = resolveOpenSsl3Or4();
    generatePkcs12WithOpenSsl(opensslBin, password);
  }
  chmodSync(keystore, 0o600);
  writeFileSync(
    properties,
    `storeFile=${keystore}\nstorePassword=${password}\nkeyAlias=${keyAlias}\nkeyPassword=${password}\n`,
    { mode: 0o600, flag: "wx" }
  );
  chmodSync(properties, 0o600);
}

if (process.argv.includes("--github")) {
  const ciStorePath = "/tmp/cloudtune-android-release.p12";
  const secrets = [
    ["CLOUDTUNE_ANDROID_KEYSTORE", readFileSync(keystore).toString("base64")],
    [
      "CLOUDTUNE_ANDROID_SIGNING",
      readFileSync(properties, "utf8").replace(/^storeFile=.*$/m, `storeFile=${ciStorePath}`),
    ],
  ];
  for (const [name, value] of secrets) {
    const res = spawnSync("gh", ["secret", "set", name, "--repo", repoSlug], {
      input: value,
      stdio: ["pipe", "pipe", "pipe"],
    });
    if (res.status !== 0) {
      throw new Error(`Could not store GitHub repository secret ${name}`);
    }
  }
  console.log("Android release signing secrets configured on GitHub");
}

console.log(`CLOUDTUNE_ANDROID_SIGNING_PROPERTIES=${properties}`);
