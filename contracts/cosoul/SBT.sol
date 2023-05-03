// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.2;

import "@openzeppelinupgrade/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelinupgrade/contracts/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelinupgrade/contracts/access/OwnableUpgradeable.sol";

contract CoSoul is ERC721Upgradeable, OwnableUpgradeable {
	using ECDSAUpgradeable for bytes32;

	bool public initiated;
	address public signer;
	mapping(address => bool) public authorisedCallers;
	mapping(uint256 => uint256) public transferNonces;
	mapping(uint256 => uint256) public syncNonces;
	mapping(uint256 => uint256) public burnNonces;
	mapping(address => uint256) public mintNonces;
	uint256 public counter;
	// blobs are uint256 storage divided in 8 uint32 slots
	mapping(uint256 => uint256) public blobs;
	

	modifier authorised(address _operator) {
		require(authorisedCallers[_operator] || _operator == owner());
		_;
	}

	/**
	 * @notice
	 * Init function called during proxy setup
	 * @param __name Name of SBT
	 * @param __symbol Symbol of SBT
	 * @param _signer Address that will provide valid signatures
	 */
	function initialize(string memory __name, string memory __symbol, address _signer) public initializer {
		__Ownable_init();
		__ERC721_init(__name, __symbol);
		signer = _signer;
	}

	/**
	 * @notice
	 * Set a new signer. Owner gated
	 * @param _signer New signer
	 */
	function setSigner(address _signer) external onlyOwner {
		signer = _signer;
	}


	/**
	 * @notice
	 * Set a addreses capable of updating blob data of SBTs
	 * @param _caller New signer
	 * @param _val Boolean to set/unset
	 */
	function setCallers(address _caller, bool _val) external onlyOwner {
		authorisedCallers[_caller] = _val;
	}

	/**
	 * @notice
	 * Getter function to get the value in a specific slot of a given blob
	 * @param _slot Slot value. Up to 7
	 * @param _tokenId Token ID from which to get the blob data
	 */
	function getSlot(uint8 _slot, uint256 _tokenId) public view returns(uint256 value) {
		require(_slot < 8);

		uint256 current = blobs[_tokenId];
		// uint32 mask that is left shifted to fetch correct slot
		uint256 mask = 0xffffffff << _slot;
		value = (current & mask) >> _slot;
	}

	/**
	 * @notice
	 * Function to update the value of a slot in a blob
	 * @param _slot Slot value. Up to 7
	 * @param _amount Amout to update
	 * @param _tokenId Token ID from which to update the blob data
	 */
	function setSlot(uint256 _slot, uint32 _amount, uint256 _tokenId) external authorised(msg.sender) {
		require(_slot < 8);

		uint256 current = blobs[_tokenId];
		// get the inverse of the slot mask 
		uint256 inverseMask = ~(0xffffffff << _slot);
		// filter current blob with inverse mask to remove the current slot and update it (OR operation) to add slot
		blobs[_tokenId] = (current & inverseMask) | (_amount << _slot);
	}

	/**
	 * @notice
	 * Function to increment the value of a slot in a blob by some amount
	 * @param _slot Slot value. Up to 7
	 * @param _amount Amout to increment a slot
	 * @param _tokenId Token ID from which to update the blob data
	 */
	function incSlot(uint8 _slot, uint256 _amount, uint256 _tokenId) external authorised(msg.sender) {
		require(_slot < 8);
		uint256 value = getSlot(_slot, _tokenId);
		require(value + _amount <= type(uint32).max, "CoSoul: uint32 overflow");
		uint256 current = blobs[_tokenId];
		blobs[_tokenId] = current + (_amount << _slot);
	}

	/**
	 * @notice
	 * Function to decrement the value of a slot in a blob by some amount
	 * @param _slot Slot value. Up to 7
	 * @param _amount Amout to decrement a slot
	 * @param _tokenId Token ID from which to update the blob data
	 */
	function decSlot(uint8 _slot, uint256 _amount, uint256 _tokenId) external authorised(msg.sender) {
		require(_slot < 8);
		uint256 value = getSlot(_slot, _tokenId);
		require(value >= _amount, "CoSoul: uint32 overflow");
		uint256 current = blobs[_tokenId];
		blobs[_tokenId] = current - (_amount << _slot);
	}

	/**
	 * @notice
	 * Function to sync blob data of a token from a merkle tree signed by our signer
	 * @param _data Blob data that will overwrite current data
	 * @param _tokenId Token ID from which to update blob
	 * @param _nonce Sync counter used to prevent replays
	 * @param _signature Signature provided by our signer to validate leaf data
	 */
	function syncWithSignature(uint256 _data ,uint256 _tokenId, uint256 _nonce, bytes calldata _signature) external {
		require(ownerOf(_tokenId) == msg.sender);
		require(syncNonces[_nonce]++ == _nonce);
		require(keccak256(abi.encodePacked(_tokenId, _nonce, _data)).toEthSignedMessageHash().recover(_signature) == signer, "Sig not valid");

		blobs[_tokenId] = _data;
	}

	/**
	 * @notice
	 * Function to transfer token under approval of the protocol. Gated by authorised addresses
	 * @param _from Previous token owner
	 * @param _to New token owner
	 * @param _tokenId Token to transfer
	 */
	function overrideTransfer(address _from, address _to, uint256 _tokenId) external authorised(msg.sender) {
		_transfer(_from, _to, _tokenId);
	}

	/**
	 * @notice
	 * Function to transfer token under approval of the protocol via signature
	 * @param _from Previous token owner
	 * @param _to New token owner
	 * @param _tokenId Token to transfer
	 * @param _nonce Transfer counter used to prevent replays
	 * @param _signature Signature provided by our signer to validate transfer
	 */
	function overrideTransferWithSignature(
		address _from,
		address _to,
		uint256 _tokenId,
		uint256 _nonce,
		bytes calldata _signature) external {
		require(ownerOf(_tokenId) == msg.sender);
		require(transferNonces[_tokenId]++ == _nonce);
		require(keccak256(abi.encodePacked(_tokenId, _nonce)).toEthSignedMessageHash().recover(_signature) == signer, "Sig not valid");

		_transfer(_from, _to, _tokenId);
	}

	/**
	 * @notice
	 * Function to mint token via signature to msg.sender
	 * @param _nonce Mint counter used to prevent replays
	 * @param _signature Signature provided by our signer to validate mint
	 */
	function mintWithSignature(uint256 _nonce, bytes calldata _signature) external {
		require(balanceOf(msg.sender) == 0);
		require(mintNonces[msg.sender]++ == _nonce);
		require(keccak256(abi.encodePacked(msg.sender, _nonce)).toEthSignedMessageHash().recover(_signature) == signer, "Sig not valid");
		
		_mint(msg.sender, ++counter);
	}

	/**
	 * @notice
	 * Function to mint token via signature to msg.sender
	 * @param _tokenId Token ID to be burnt (fiiire)
	 * @param _nonce Burn counter used to prevent replays
	 * @param _signature Signature provided by our signer to validate burn
	 */
	function burnWithSignature( uint256 _tokenId, uint256 _nonce, bytes calldata _signature) external {
		require(ownerOf(_tokenId) == msg.sender); // not necessary?
		require(burnNonces[_tokenId]++ == _nonce);
		require(keccak256(abi.encodePacked(_tokenId, _nonce)).toEthSignedMessageHash().recover(_signature) == signer, "Sig not valid");
		
		blobs[_tokenId] = 0;
		_burn(_tokenId);
	}

	function transferFrom(address from, address to, uint256 tokenId) public override {
		revert("nope");
	}

	function safeTransferFrom(address from, address to, uint256 tokenId) public override {
		revert("nope");
	}

	function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) public override {
		revert("nope");
	}
}