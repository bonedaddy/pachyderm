#!/bin/bash
# This script generates a self-signed TLS cert to be used by pachd in tests

if [[ -n "${ADDRESS}" ]] || [[ -n "${PACHD_ADDRESS}" ]]; then
  echo -n "must run 'unset ADDRESS; unset PACHD_ADDRESS' to use " >/dev/fd/2
  echo "this script's cert" >/dev/fd/2
  exit 1
fi

eval "set -- $( getopt -l "dns:,ip:,port:" -o "o:" "--" "${0}" "${@:-}" )"
output_prefix=pachd
while true; do
  case "${1}" in
    --dns)
      dns="${2}"
      shift 2
      ;;
    --ip)
      ip="${2}"
      shift 2
      ;;
    --port)
      port="${2}"
      shift 2
      ;;
    -o)
      output_prefix="${2}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      cat <<EOF
Unrecognized arg "${1}". Usage:
Generate a self-signed TLS certificate for Pachyderm

Args:
  --dns  Set the domain name in the certificate (i.e. the common name with
         which pachd will authenticate)

  --ip   The IP address in the certificate (which you plan to use to connect
         to pachd. Without this, enabling TLS while connecting to pachd over
         an IP will not work)

   -o <prefix>
        This script generates a public TLS cert at <prefix>.pem and <prefix>.key
        Setting this arg determines the output file names.
EOF
  esac
done

# Validate flags
if [[ -z "${dns}" ]] && [[ -z "${ip}" ]]; then
  echo "You must set either --dns or --ip" >/dev/fd/2
  exit 1
fi
dns="${dns:-localhost}"
ip="${ip:-127.0.0.1}"
if [[ -z "${port}" ]]; then
  echo -n "Warning, --port is unset. Assuming :30650 (cert will " >/dev/fd/2
  echo "not work if this is not the correct port)" >/dev/fd/2
  exit 1
fi

# Define a minimal openssl config for our micro-CA
read -d '' -r tls_config <<EOF
[ req ]
default_md         = sha256 # MD = message digest. md5 is the openSSL default in 1.1.0 (see 'man req')
prompt             = no     # use values in [dn] directly
distinguished_name = dn
x509_extensions    = exn    # Since we're making self-signed certs. For CSRs, use req_extensions

[ dn ]
CN = ${dns}

[ exn ]
EOF

# If 'ip' is set, include IP in TLS cert
if [[ -n "${ip}" ]]; then
  tls_config+=$'\n'"subjectAltName = IP:${ip}"
fi

echo "${tls_config}"

# Set other openssl options
tls_opts=(
  # Immediately self-sign the generated CSR and output that, instead of
  # outputting the CSR itself
  -x509

  # Don't encrypt (DES) the resulting cert (dangerous, non-prod only)
  -nodes

  # signed cert should be valid for 1 year
  -days 365

  # Generate the cert's private key as well (instead of receiving one)
  -newkey rsa:2048

  # Output the private key here # Output the private key here
  -keyout ${output_prefix}.key

  # Output PEM-encoded cert (this is the default, and this flag is unnecessary,
  # but PEM is required by kubernetes and this makes explicit the fact that
  # we're meeting that requirement
  -outform PEM

  # Output path for the self-signed cert
  -out ${output_prefix}.pem
)

# Generate self-signed cert
openssl req "${tls_opts[@]}" -config <(echo "${tls_config}")

# Copy pachd public key to pachyderm config
echo "Backing up Pachyderm config to \$HOME/.pachyderm/config.json.backup"
echo "New config with address and cert is at \$HOME/.pachyderm/config.json"
cp ~/.pachyderm/config.json ~/.pachyderm/config.json.backup
jq ".v1.pachd_address = \"${dns}:${port}\" | .v1.server_cas = \"$(cat ./pachd.pem | base64)\"" ~/.pachyderm/config.json.backup >~/.pachyderm/config.json
