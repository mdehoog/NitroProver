// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";

import { Curve384 } from "marlinprotocol/P384/Curve384.sol";
import { Sha2Ext } from "marlinprotocol/SolSha2Ext/Sha2Ext.sol";
import { LibBytes } from "marlinprotocol/SolSha2Ext/LibBytes.sol";
import { ByteParser } from "marlinprotocol/solidity-cbor/ByteParser.sol";
import { Asn1Decode } from "./lib/Asn1Decode.sol";
import { DateTimeLibrary } from "./lib/DateTimeLibrary.sol";
import { BytesUtils } from "./lib/BytesUtils.sol";

// @title CertManager
// @notice Allows verification of AWS certificates in Solidity
contract CertManager is Curve384 {
    using Asn1Decode for bytes;

    // @dev download the root CA cert for AWS nitro enclaves from https://aws-nitro-enclaves.amazonaws.com/AWS_NitroEnclaves_Root-G1.zip
    // @dev convert the base64 encoded pub key into hex to get the cert below
    bytes public constant ROOT_CA_CERT = hex"3082021130820196a003020102021100f93175681b90afe11d46ccb4e4e7f856300a06082a8648ce3d0403033049310b3009060355040613025553310f300d060355040a0c06416d617a6f6e310c300a060355040b0c03415753311b301906035504030c126177732e6e6974726f2d656e636c61766573301e170d3139313032383133323830355a170d3439313032383134323830355a3049310b3009060355040613025553310f300d060355040a0c06416d617a6f6e310c300a060355040b0c03415753311b301906035504030c126177732e6e6974726f2d656e636c617665733076301006072a8648ce3d020106052b8104002203620004fc0254eba608c1f36870e29ada90be46383292736e894bfff672d989444b5051e534a4b1f6dbe3c0bc581a32b7b176070ede12d69a3fea211b66e752cf7dd1dd095f6f1370f4170843d9dc100121e4cf63012809664487c9796284304dc53ff4a3423040300f0603551d130101ff040530030101ff301d0603551d0e041604149025b50dd90547e796c396fa729dcf99a9df4b96300e0603551d0f0101ff040403020186300a06082a8648ce3d0403030369003066023100a37f2f91a1c9bd5ee7b8627c1698d255038e1f0343f95b63a9628c3d39809545a11ebcbf2e3b55d8aeee71b4c3d6adf3023100a2f39b1605b27028a5dd4ba069b5016e65b4fbde8fe0061d6a53197f9cdaf5d943bc61fc2beb03cb6fee8d2302f3dff6";
    bytes32 public constant ROOT_CA_CERT_HASH = keccak256(ROOT_CA_CERT);
    // OID 1.2.840.10045.4.3.3 represents {iso(1) member-body(2) us(840) ansi-x962(10045) signatures(4) ecdsa-with-SHA2(3) ecdsa-with-SHA384(3)}
    // which essentially means the signature algorithm is Elliptic curve Digital Signature Algorithm (DSA) coupled with the Secure Hash Algorithm 384 (SHA384) algorithm
    // @dev Sig algo is hardcoded here because the root cerificate's sig algorithm is known beforehand
    // @dev reference article for encoding https://learn.microsoft.com/en-in/windows/win32/seccertenroll/about-object-identifier
    bytes public constant CERT_ALGO_OID = hex"06082a8648ce3d040303";
    // https://oid-rep.orange-labs.fr/get/1.2.840.10045.2.1
    // 1.2.840.10045.2.1 {iso(1) member-body(2) us(840) ansi-x962(10045) keyType(2) ecPublicKey(1)} represents Elliptic curve public key cryptography
    bytes public constant EC_PUB_KEY_OID = hex"2a8648ce3d0201";
    // https://oid-rep.orange-labs.fr/get/1.3.132.0.34
    // 1.3.132.0.34 {iso(1) identified-organization(3) certicom(132) curve(0) ansip384r1(34)} represents NIST 384-bit elliptic curve
    bytes public constant SECP_384_R1_OID = hex"2b81040022";

    // certHash -> pub key that verified cert
    mapping(bytes32 => bytes) public verifiedBy;
    // certHash -> pub key of the cert
    mapping(bytes32 => bytes) public certPubKey;

    constructor() {
        bytes memory emptyPubKey;
        certPubKey[ROOT_CA_CERT_HASH] = _verifyCert(ROOT_CA_CERT, emptyPubKey);
    }

    event CertificateVerified(bytes32 indexed certHash, bytes certificate, bytes certPubKey, bytes32 indexed parentCertHash, bytes parentPubKey);

    function verifyCert(bytes memory certificate, bytes32 parentCertHash) external {
        bytes memory parentPubKey = certPubKey[parentCertHash];
        require(parentPubKey.length != 0, "VC1");
        bytes32 certHash = keccak256(certificate);
        require(certPubKey[certHash].length == 0, "VC2");
        certPubKey[certHash] = _verifyCert(certificate, parentPubKey);
        verifiedBy[certHash] = parentPubKey;
        emit CertificateVerified(certHash, certificate, certPubKey[certHash], parentCertHash, parentPubKey);
    }

    function verifyCertBundle(bytes memory certificate, bytes[] memory cabundle) external view returns(bytes memory) {
        bytes32 rootCertHash = keccak256(cabundle[0]);
        require(rootCertHash == ROOT_CA_CERT_HASH, "Root CA cert not matching");

        bytes memory pubKey;
        for(uint256 i=0; i < cabundle.length; i++) {
            pubKey = _verifyCert(cabundle[i], pubKey);
            require(pubKey.length != 0, "invalid pub key");
        }
        pubKey = _verifyCert(certificate, pubKey);

        return pubKey;
    }

    function _verifyCert(bytes memory certificate, bytes memory parentPubKey) internal view returns(bytes memory) {
        bytes32 certHash = keccak256(certificate);
        // skip verification if already verified
        if(certPubKey[certHash].length != 0) {
            require(keccak256(verifiedBy[certHash]) == keccak256(parentPubKey), "parent incorrect");
            return certPubKey[certHash];
        }

        uint256 root = certificate.root();
        uint256 tbsCertPtr = certificate.firstChildOf(root);
        // TODO: extract and check issuer and subject hash
        bytes memory pubKey = _parseTbs(certificate, tbsCertPtr);
        if(parentPubKey.length == 0 && certHash == ROOT_CA_CERT_HASH) return pubKey;
        bytes memory tbs = certificate.allBytesAt(tbsCertPtr);
        uint256 sigAlgoPtr = certificate.nextSiblingOf(tbsCertPtr);
        require(keccak256(certificate.bytesAt(sigAlgoPtr)) == keccak256(CERT_ALGO_OID), "invalid cert sig algo");

        bytes memory sigPacked = packSig(certificate, sigAlgoPtr);

        verifyES384WithSHA384(parentPubKey, tbs, sigPacked);
        return pubKey;
    }

    function packSig(bytes memory certificate, uint256 sigAlgoPtr) internal pure returns(bytes memory) {
        uint256 sigPtr = certificate.nextSiblingOf(sigAlgoPtr);
        bytes memory sig = certificate.bitstringAt(sigPtr);
        uint256 sigRoot = sig.root();
        uint256 sigXPtr = sig.firstChildOf(sigRoot);
        bytes memory sigX = sig.uintBytesAt(sigXPtr);
        uint256 sigYPtr = sig.nextSiblingOf(sigXPtr);
        bytes memory sigY = sig.uintBytesAt(sigYPtr);

        return abi.encodePacked(pad(sigX, 48), pad(sigY, 48));
    }

    function pad(bytes memory b, uint256 l) internal pure returns(bytes memory) {
        require(b.length <= l, "");
        if(b.length == l) return b;
        bytes memory padding = new bytes(l - b.length);
        return abi.encodePacked(padding, b);
    }

    function _parseTbs(bytes memory certificate, uint256 ptr) internal view returns(bytes memory pubKey) {
        uint256 versionPtr = certificate.firstChildOf(ptr);
        uint256 vPtr = certificate.firstChildOf(versionPtr);
        uint256 version = certificate.uintAt(vPtr);
        // as extensions are used in cert, version should be 3 (value 2) as per https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.1
        require(version == 2, "version should be 3");

        uint256 serialPtr = certificate.nextSiblingOf(versionPtr);
        // TODO: are there any checks on serialPtr other than being +ve?

        uint256 sigAlgoPtr = certificate.nextSiblingOf(serialPtr);
        require(keccak256(certificate.bytesAt(sigAlgoPtr)) == keccak256(CERT_ALGO_OID), "invalid cert sig algo");

        pubKey = _parseTbs2(certificate, sigAlgoPtr);
    }

    function _parseTbs2(bytes memory certificate, uint256 sigAlgoPtr) internal view returns (bytes memory pubKey) {
        uint256 issuerPtr = certificate.nextSiblingOf(sigAlgoPtr);
        // TODO: add checks on issuer

        uint256 validityPtr = certificate.nextSiblingOf(issuerPtr);
        uint256 notBeforePtr = certificate.firstChildOf(validityPtr);
        require(yymmddhhmmssTots(certificate.bytesAt(notBeforePtr)) <= block.timestamp, "certificate not valid yet");
        uint256 notAfterPtr = certificate.nextSiblingOf(notBeforePtr);
        require(yymmddhhmmssTots(certificate.bytesAt(notAfterPtr)) >= block.timestamp, "certificate not valid anymore");

        uint256 subjectPtr = certificate.nextSiblingOf(validityPtr);
        // TODO: are there any checks on subject
        // TODO: need to check if issuer of this cert is the parent cert

        pubKey = _verifyTbs2(certificate, certificate.nextSiblingOf(subjectPtr));
    }

    function _verifyTbs2(bytes memory certificate, uint256 subjectPublicKeyInfoPtr) internal pure returns(bytes memory) {
        uint256 pubKeyAlgoPtr = certificate.firstChildOf(subjectPublicKeyInfoPtr);
        uint256 pubKeyAlgoIdPtr = certificate.firstChildOf(pubKeyAlgoPtr);
        require(keccak256(certificate.bytesAt(pubKeyAlgoIdPtr)) == keccak256(EC_PUB_KEY_OID), "Cert Algo id Incorrect");

        uint256 algoParamsPtr = certificate.nextSiblingOf(pubKeyAlgoIdPtr);
        require(keccak256(certificate.bytesAt(algoParamsPtr)) == keccak256(SECP_384_R1_OID), "Cert algo param incorrect");

        uint256 subjectPublicKeyPtr = certificate.nextSiblingOf(pubKeyAlgoPtr);
        bytes memory subjectPubKey = certificate.bitstringAt(subjectPublicKeyPtr);

        // uint256 extensionsPtr = certificate.nextSiblingOf(subjectPublicKeyInfoPtr);
        // TODO: verify extensions based on 3.2.3.2 section in https://github.com/aws/aws-nitro-enclaves-nsm-api/blob/main/docs/attestation_process.md#32-syntactical-validation

        return subjectPubKey;
    }

    function yymmddhhmmssTots(bytes memory time) public pure returns(uint256) {
        uint256 year = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 0, 2))) + 2000;
        uint256 month = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 2, 2)));
        uint256 day = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 4, 2)));
        uint256 hour = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 6, 2)));
        uint256 minute = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 8, 2)));
        uint256 second = bytesToUint(abi.encodePacked(BytesUtils.readBytesN(time, 10, 2)));
        uint256 ts = DateTimeLibrary.timestampFromDateTime(year, month, day, hour, minute, second);
        return ts;
    }

    function bytesToUint(bytes memory b) public pure returns (uint) {
        uint result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 c = uint256(uint8(b[i]));
            if (c >= 48 && c <= 57) {
                result = result * 10 + (c - 48);
            }
        }
        return result;
    }

    function verifyES384WithSHA384(bytes memory pk, bytes memory message, bytes memory sig) internal view {
        require(pk.length == 97, "invalid pub key length");
        require(sig.length == 96, "invalid sig length");
        (bytes16 mhi, bytes32 mlo) = Sha2Ext.sha384(message);
        C384Elm memory pub = _parsePubKey(pk);
        (uint256 rhi, uint256 rlo, uint256 shi, uint256 slo) = _parseSig(sig);
        require(verify(pub, uint256(bytes32(abi.encodePacked(bytes16(0), mhi))), uint256(mlo), rhi, rlo, shi, slo), "invalid sig");
    }

    function _parsePubKey(bytes memory pk) private pure returns(C384Elm memory pub) {
        pub.xhi = uint256(bytes32(abi.encodePacked(bytes16(0), bytes16(LibBytes.slice(pk, 1, 17)))));
        pub.xlo = uint256(bytes32(LibBytes.slice(pk, 17, 49)));
        pub.yhi = uint256(bytes32(abi.encodePacked(bytes16(0), bytes16(LibBytes.slice(pk, 49, 65)))));
        pub.ylo = uint256(bytes32(LibBytes.slice(pk, 65, 97)));
    }

    function _parseSig(bytes memory sig) private pure returns(uint256 rhi, uint256 rlo, uint256 shi, uint256 slo) {
        rhi = uint256(bytes32(abi.encodePacked(bytes16(0), bytes16(LibBytes.slice(sig, 0, 16)))));
        rlo = uint256(bytes32(LibBytes.slice(sig, 16, 48)));
        shi = uint256(bytes32(abi.encodePacked(bytes16(0), bytes16(LibBytes.slice(sig, 48, 64)))));
        slo = uint256(bytes32(LibBytes.slice(sig, 64, 96)));
    }
}
