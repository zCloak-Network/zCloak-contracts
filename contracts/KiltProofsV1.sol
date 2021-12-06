///
/// @dev The function that works are isValid() and isPassed(). The smart contract only use these
/// two functions transfer the data to worker. The worker implement the calculation logic of these
/// two functions.
///

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IRegistry.sol";
import "./Properties.sol";
import "./interfaces/IWorker.sol";

contract KiltProofsV1 is AccessControl, Properties {

    bytes32 public constant NULL = "";
    bytes32 public constant REGULATED_ERC20 = "REGULATED_ERC20";
    
    struct Credential {
        bytes32 kiltAddress;
        // rootHash to prove the validity of the private data
        mapping(bytes32 => uint256) approvedRootHash;
        bytes32 finalRootHash;
    }

    struct StarkProof {
        address owner;
        string fieldName;
        string proofCid;
        mapping(bool => uint256) approveCount;
        bool isFinal; // has reached the final result or not
        bool isPassed;
    }

    // storage
    IRegistry public registry;


    // address => cType => Credential
    mapping(address => mapping(bytes32 => Credential)) public certificate;

    // address => (cType => (programHash => StarkProof)))
    mapping(address => mapping(bytes32 => mapping(bytes32 => StarkProof))) public proofs;

    // expected output
    // cType => programHash => expectedResult
    mapping(bytes32 => mapping(bytes32 => bool)) expectedResult;

    // For third parties
    // contract address => cType => programHash
    mapping(address => mapping(bytes32 => bytes32)) public trustedPrograms;
   
    event AddProof(address dataOwner, bytes32 kiltAddress, bytes32 cType, bytes32 programHash, string fieldName, string proofCid, bytes32 rootHash, bool expectResult);
    event AddVerification(address dataOwner, address worker, bytes32 rootHash, bool isPassed);
    event FinalCredential(address dataowner, bytes32 cType, bytes32 rootHash);
    event VerificationDone(address dataOwner, bytes32 cType, bytes32 programHash, bool isPassed);
    event RegisterService(address consumer, bytes32 cType, bytes32 programHash, bool expectedResult);

    constructor(IRegistry _registry) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(REGULATED_ERC20, DEFAULT_ADMIN_ROLE);
        registry = _registry;
    }

    modifier isWorker(address _worker) {
        IWorker whitelist = IWorker(registry.addressOf(Properties.CONTRACT_WHITELIST));
        require(whitelist.isWorker(_worker));
        _;
    }

    // TODO: complete this later!
    // add projects registration
    modifier isRegistered(address _who, bytes32 _cType) {
        require(trustedPrograms[_who][_cType] != NULL);
        _;
    }

    function addProof(
        bytes32 _kiltAddress, 
        bytes32 _cType,
        string memory _fieldName,
        bytes32 _programHash, 
        string memory _proofCid,
        bytes32 _rootHash,
        bool _expectResult
    ) public {
        _addProof(msg.sender, _kiltAddress, _cType, _fieldName, _programHash, _proofCid, _rootHash, _expectResult);
    }

    function addVerification(
        address _dataOwner,  
        bytes32 _rootHash,
        bytes32 _cType,
        bytes32 _programHash,
        bool _isPassed // proof verification result
    ) public isWorker(msg.sender) {
        _addVerification(_dataOwner, _rootHash, _cType, _programHash, _isPassed);
    }

   
    // TODO: check existence
    function _addProof(
        address _user,
        bytes32 _kiltAddress, 
        bytes32 _cType,
        string memory _fieldName,
        bytes32 _programHash, 
        string memory _proofCid,
        bytes32 _rootHash,
        bool _result
    ) internal {
        require(_result == expectedResult[_cType][_programHash], "not qualified.");
        StarkProof storage proof = proofs[_user][_cType][_programHash];
        proof.fieldName = _fieldName;
        proof.owner = _user;
        proof.proofCid = _proofCid;
        
        Credential storage credential =  certificate[_user][_cType];
        credential.kiltAddress = _kiltAddress;

        emit AddProof(_user, _kiltAddress, _cType, _programHash, _fieldName, _proofCid, _rootHash, _result);
    }



    // TODO: reward worker？
    function _addVerification(
        address _dataOwner,  
        bytes32 _rootHash,
        bytes32 _cType,
        bytes32 _programHash,
        bool _isPassed // proof verification result
    ) internal {

        Credential storage credential = certificate[_dataOwner][_cType];
        // successfully finalized the validity if true
        _apporveCredential(_dataOwner, _cType, credential, _rootHash);
        StarkProof storage proof = proofs[_dataOwner][_cType][_programHash];
        _approveStarkProof(_cType, _programHash, proof, _isPassed);
        
        emit AddVerification(_dataOwner, msg.sender, _rootHash, _isPassed);
    }

    function _apporveCredential(
        address _dataOwner,
        bytes32 _cType,
        Credential storage _credential, 
        bytes32 _rootHash
    ) internal returns (bool) {

        uint threshold = registry.uintOf(Properties.UINT_APPROVE_THRESHOLD);
        _credential.approvedRootHash[_rootHash]++;
        if (_credential.approvedRootHash[_rootHash] >= threshold) {
            _credential.finalRootHash = _rootHash;
            emit FinalCredential(_dataOwner, _cType, _rootHash);
            return true;
        }
        return false;
    }

    function _approveStarkProof(
        bytes32 _cType,
        bytes32 _programHash,
        StarkProof storage _proof, 
        bool _isPassed
    ) internal {
         uint threshold = registry.uintOf(Properties.UINT_APPROVE_THRESHOLD);
        _proof.approveCount[_isPassed]++;
        if (_proof.approveCount[_isPassed] >= threshold) {
            // reach the threshold AND proof is verified true
            _proof.isFinal = true;
            _proof.isPassed = _isPassed;
            emit VerificationDone(_proof.owner, _cType, _programHash, _isPassed);
        }
    }

    /// @param _who the function isValid's parameter is rootHash 
    function isValid(address _who, bytes32 _cType) isRegistered(_who, _cType) public view returns (bool) {
        Credential storage credential = certificate[_who][_cType];
        return credential.finalRootHash == NULL;
    }

    /// @param _who the function isPassed's parameter are program, output and proof
    function isPassed(
        address _who, 
        bytes32 _programHash, 
        bytes32 _cType
    ) isRegistered(_who, _cType) public view returns (bool) {
    
        StarkProof storage proof = proofs[_who][_cType][_programHash];
        return proof.isPassed && proof.isFinal;
    }

    function addService(
        address _project, 
        bytes32 _cType,
        bytes32 _programHash, 
        bool _expectedResult
        ) onlyRole(REGULATED_ERC20) public returns (bool) {
        trustedPrograms[_project][_cType] = _programHash;
        expectedResult[_cType][_programHash] = _expectedResult;

        emit RegisterService(_project, _cType, _programHash, _expectedResult);
        return true;
    }
}
