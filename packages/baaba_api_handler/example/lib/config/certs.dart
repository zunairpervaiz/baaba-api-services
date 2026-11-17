/// Certificates for the example's pinned client.
///
/// **This is a throwaway test CA** generated for this package's tests
/// (`test/fixtures/tls/ca.pem`); nothing real is signed by it, so pinning to
/// it means `partner.example.net` — itself a placeholder — would be refused
/// even if it existed. In an app, paste the PEM of the root or intermediate
/// CA that issues your partner's certificate, and add the next CA alongside
/// it before they rotate.
abstract final class Certs {
  static const String partnerRootCa = '''
-----BEGIN CERTIFICATE-----
MIIDRTCCAi2gAwIBAgIUaJIapxepG/Hse2w3hhhusG8/Fv4wDQYJKoZIhvcNAQEL
BQAwKTEnMCUGA1UEAwweYmFhYmFfYXBpX2hhbmRsZXIgVGVzdCBSb290IENBMCAX
DTI2MTExNzA1MjIxM1oYDzIxMjYxMDI0MDUyMjEzWjApMScwJQYDVQQDDB5iYWFi
YV9hcGlfaGFuZGxlciBUZXN0IFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IB
DwAwggEKAoIBAQCwk5mev5BIilXmEBcbZBK3mR7Oh+APV1CYNnRj6NOGFLYY77/E
FyGDac6i9D+jL4GqjAsRdWtxH5q/vvtwvAPlowrFCsV3ywo6feMxWq1tTFZcTiNo
5C7sFnPLArNUofUwMSBp4f8Ph838bJzd8SqtAiJ422UYTWjPgTRQ19m8Ul//w2eE
jea/P/GgBPSYt82dC7C452AZBOvSWtcP7gQyZ13iHtgTTZ3Bu6pF4oZ1lwj3PshI
t1TanxCWesLVODgqGIT64ahPLBVZRMnEttykM59r1nLgHQdn62x2B1Pkoi20zNbT
/8I/MT7MIuo1jYTB8dwkMVWms7GEDmxTFLiVAgMBAAGjYzBhMB0GA1UdDgQWBBQr
vRaEkE6PjcgOyocfbZ44uCIzljAfBgNVHSMEGDAWgBQrvRaEkE6PjcgOyocfbZ44
uCIzljAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0B
AQsFAAOCAQEAc+wmMQREQ5C4buW6xJnaVxJCMA6XC8GVEiHuIGYqm52v6cbiHSaF
7dyW0Ib/WsLKco9F/U7tJcwLQpTceL5/T48oRItaCNNZMz8Nz2Sw0bIC/FkaeRJ+
LstCsWYT5oPwbGCxqG2n3N9noEmE+3noZctLkSSxW9LXqh0JmxvHnD5sMq4MZv8H
fgjloCXwx5RAJCJ8jYZhCRUBl8Pq14cOU8qzENLaD0dN1pzCenPFJ4H+1hS9p6hp
p/Ch+O9Pctfwi3AmWnEnc8I7hpvSX+dQLyrpfuIzeHomiF5jcRlZ/wef6FXLaXcX
n3PhCfdoutkUZ0xq/GZN9pBTpWvZryFPnA==
-----END CERTIFICATE-----
''';
}
