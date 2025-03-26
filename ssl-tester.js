const tls = require('tls');

function printCertificateChain(host, port = 443) {
  const socket = tls.connect(port, host, { servername: host }, () => {
    const certChain = socket.getPeerCertificate(true); // true = detailed

    if (!certChain || !certChain.raw) {
      console.error('Failed to get certificate chain.');
      socket.end();
      return;
    }

    // The detailed mode returns a single object with a `raw` buffer and `issuerCertificate`
    let cert = certChain;
    let i = 1;

    while (cert) {
      console.log(`\n🔐 Certificate ${i}`);
      console.log(`Subject: ${cert.subject?.CN}`);
      console.log(`Issuer: ${cert.issuer?.CN}`);
      console.log(`Valid From: ${cert.valid_from}`);
      console.log(`Valid To: ${cert.valid_to}`);
      console.log(`Serial Number: ${cert.serialNumber}`);

      if (
        !cert.issuerCertificate ||
        cert.issuerCertificate === cert || // Self-signed root
        !cert.issuerCertificate.raw
      ) {
        break;
      }

      cert = cert.issuerCertificate;
      i++;
    }

    socket.end();
  });

  socket.on('error', (err) => {
    console.error(`Connection error: ${err.message}`);
  });
}

printCertificateChain('registry.npmjs.org');
