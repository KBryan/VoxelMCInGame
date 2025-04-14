// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "./libraries/Base64.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Custom errors
error AddressAlreadyHasNFT(address owner);
error CharacterAlreadyMinted(uint256 tokenId);
error TokenDoesNotExist(uint256 tokenId);
error NotTokenOwner(address caller, uint256 tokenId, address owner);
error InsufficientTokenBalance(address account, uint256 required, uint256 available);
error InsufficientContractBalance(uint256 requested, uint256 available);
error TokenTransferFailed();
error TransfersDisabled();
error TooEarlyToClaim(uint256 tokenId, uint256 nextClaimTime);
error InvalidAddress(address addr);
error NonexistentToken(uint256 tokenId);

contract VoxelVerseMC is ERC721, Ownable {
    using Strings for uint256;

    IERC20 public tokenAddress;
    uint256 public dripAmount;
    uint256 public dripCooldown = 1 days;
    bool public transfersEnabled = false; // Default: transfers disabled (soulbound)

    uint256 private tokenId;
    uint256 public constant FREE_MINT_LIMIT = 250;
    uint256 public constant MINT_PRICE = 1000 * 10 ** 18; // 1000 VOXEL tokens

    struct CharacterAttributes {
        string name;
        string imageURI;
        uint256 happiness;
        uint256 thirst;
        uint256 hunger;
        uint256 xp;
        uint256 daysSurvived;
        uint256 characterLevel;
        uint256 health;
        uint256 heat;
    }
    // No need to store token balance directly in struct as we'll get it dynamically

    // Add lastDripClaim to track when each token last claimed a drip
    mapping(uint256 => uint256) public lastDripClaim;
    mapping(uint256 => CharacterAttributes) public nftHolderAttributes;
    mapping(uint256 => bool) private _tokenMinted;
    mapping(address => bool) private _addressHasNFT;
    mapping(uint256 => bool) public _tokenExists;

    // Add a missed claims counter
    mapping(uint256 => uint256) public missedClaims;
    uint256 public maxMissedClaims = 3; // Allow missing 3 days before burning tokens

    event DripBurned(uint256 indexed tokenId, uint256 amount);
    event CharacterUpdated(uint256 tokenId, CharacterAttributes attributes);
    event CharacterNFTMinted(address indexed recipient, uint256 indexed tokenId, CharacterAttributes attributes);
    event DripClaimed(address indexed claimer, uint256 indexed tokenId, uint256 amount);
    event StartingTokensIssued(address indexed recipient, uint256 amount);
    event ContractRefilled(uint256 amount, uint256 newBalance);
    event PaidMint(address indexed minter, uint256 tokenId, uint256 price);

    constructor(address _tokenAddress, uint256 _dripAmount) ERC721("VoxelVerseMC", "VVMC") Ownable(msg.sender) {
        tokenAddress = IERC20(_tokenAddress);
        dripAmount = _dripAmount; // Amount of tokens to drip daily
    }

    function setDripAmount(uint256 _dripAmount) public onlyOwner {
        dripAmount = _dripAmount;
    }

    function setDripCooldown(uint256 _dripCooldown) public onlyOwner {
        dripCooldown = _dripCooldown;
    }

    function setMaxMissedClaims(uint256 _maxMissedClaims) public onlyOwner {
        maxMissedClaims = _maxMissedClaims;
    }

    // Allow owner to enable/disable transfers if needed in the future
    function setTransfersEnabled(bool _enabled) external onlyOwner {
        transfersEnabled = _enabled;
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _tokenExists[tokenId];
    }

    // Get the VOXEL token balance for a specific character's owner
    function getVoxelBalance(uint256 _tokenId) public view returns (uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        address owner = ownerOf(_tokenId);
        return tokenAddress.balanceOf(owner);
    }

    // Modified to be free for first 250 mints, then cost 1000 VOXEL
    function mintCharacterNFT() public {
        if (_addressHasNFT[msg.sender]) revert AddressAlreadyHasNFT(msg.sender);

        uint256 newItemId = tokenId;
        if (_tokenMinted[newItemId]) revert CharacterAlreadyMinted(newItemId);

        // Check if we're past the free mint limit
        bool isFreeNFT = newItemId < FREE_MINT_LIMIT;

        // If not free, check if user has enough tokens and collect payment
        if (!isFreeNFT) {
            uint256 userBalance = tokenAddress.balanceOf(msg.sender);
            if (userBalance < MINT_PRICE) {
                revert InsufficientTokenBalance(msg.sender, MINT_PRICE, userBalance);
            }

            // Transfer tokens from user to contract (payment)
            bool transferSuccess = tokenAddress.transferFrom(msg.sender, address(this), MINT_PRICE);
            if (!transferSuccess) revert TokenTransferFailed();

            // Emit paid mint event
            emit PaidMint(msg.sender, newItemId, MINT_PRICE);
        }

        // Check if contract has enough tokens for starting amount
        uint256 startingTokens = 10 * 10 ** 18; // 10 VOXEL tokens (with 18 decimals)
        _checkSufficientBalance(startingTokens);

        CharacterAttributes memory attributes = CharacterAttributes({
            name: getMinterAddressAsString(),
            imageURI: "https://harlequin-leading-egret-2.mypinata.cloud/ipfs/Qmd7NWbw2JdUqnJk7rg1w2X79L36dbrbQ5QbESVzHYt3SH",
            happiness: 50,
            thirst: 100,
            hunger: 100,
            xp: 1,
            daysSurvived: 1,
            characterLevel: 1,
            health: 100,
            heat: 50
        });

        _safeMint(msg.sender, newItemId);
        nftHolderAttributes[newItemId] = attributes;
        _tokenMinted[newItemId] = true;
        _addressHasNFT[msg.sender] = true;
        _tokenExists[newItemId] = true;

        // Set initial drip claim time to mint time
        lastDripClaim[newItemId] = block.timestamp;

        // Give the player 10 VOXEL tokens to start with
        bool success = tokenAddress.transfer(msg.sender, startingTokens);
        if (!success) revert TokenTransferFailed();

        // Emit event for the starting token grant
        emit StartingTokensIssued(msg.sender, startingTokens);

        tokenId++;

        emit CharacterNFTMinted(msg.sender, newItemId, attributes);
    }

    // New function to claim daily drip
    function claimDrip(uint256 _tokenId) external {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);

        address tokenOwner = ownerOf(_tokenId);
        if (tokenOwner != msg.sender) revert NotTokenOwner(msg.sender, _tokenId, tokenOwner);

        // Check if contract has enough tokens for the drip
        _checkSufficientBalance(dripAmount);

        // Check how many days have passed since last claim
        uint256 daysSinceLastClaim = (block.timestamp - lastDripClaim[_tokenId]) / dripCooldown;

        // If it's been more than 1 day, check if we need to burn missed claims
        if (daysSinceLastClaim > 1) {
            // Count missed days (subtract the day they're claiming now)
            uint256 missedDays = daysSinceLastClaim - 1;
            missedClaims[_tokenId] += missedDays;

            // If too many missed claims, burn the character
            if (missedClaims[_tokenId] >= maxMissedClaims) {
                // Emit event before burning
                emit DripBurned(_tokenId, dripAmount);

                // Optional: Reduce character attributes as a penalty
                CharacterAttributes storage char = nftHolderAttributes[_tokenId];
                if (char.health > 10) char.health -= 10;
                if (char.happiness > 10) char.happiness -= 10;
                emit CharacterUpdated(_tokenId, char);
            }
        }

        // Reset last claim time
        lastDripClaim[_tokenId] = block.timestamp;

        // Reset missed claims counter since they're claiming now
        missedClaims[_tokenId] = 0;

        // Transfer drip tokens to the claimer
        bool success = tokenAddress.transfer(msg.sender, dripAmount);
        if (!success) revert TokenTransferFailed();

        emit DripClaimed(msg.sender, _tokenId, dripAmount);
    }

    // Check time remaining until next drip claim
    function timeToNextDrip(uint256 _tokenId) external view returns (uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);

        uint256 timeSinceLastClaim = block.timestamp - lastDripClaim[_tokenId];

        if (timeSinceLastClaim >= dripCooldown) {
            return 0; // Can claim now
        }

        return dripCooldown - timeSinceLastClaim;
    }

    // Get the current mint price (0 if under FREE_MINT_LIMIT)
    function getCurrentMintPrice() public view returns (uint256) {
        return tokenId < FREE_MINT_LIMIT ? 0 : MINT_PRICE;
    }

    // Get the number of remaining free mints
    function getRemainingFreeMints() public view returns (uint256) {
        return tokenId >= FREE_MINT_LIMIT ? 0 : FREE_MINT_LIMIT - tokenId;
    }

    // Check the contract's token balance
    function getContractTokenBalance() public view returns (uint256) {
        return tokenAddress.balanceOf(address(this));
    }

    // Refill the contract with tokens
    function refillContract(uint256 amount) external onlyOwner {
        // Transfer tokens from owner to contract
        bool success = tokenAddress.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed();

        // Emit event
        emit ContractRefilled(amount, getContractTokenBalance());
    }

    // Check if contract has enough tokens for an operation
    function _checkSufficientBalance(uint256 amount) internal view {
        uint256 contractBalance = getContractTokenBalance();
        if (contractBalance < amount) {
            revert InsufficientContractBalance(amount, contractBalance);
        }
    }

    // Administrative function to burn unclaimed tokens in bulk
    function burnUnclaimedTokens(uint256[] calldata tokenIds) external onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 _tokenId = tokenIds[i];
            if (_exists(_tokenId)) {
                // Check how many days passed since last claim
                uint256 daysSinceLastClaim = (block.timestamp - lastDripClaim[_tokenId]) / dripCooldown;

                if (daysSinceLastClaim > 1) {
                    // Add missed days to counter
                    uint256 missedDays = daysSinceLastClaim - 1;
                    missedClaims[_tokenId] += missedDays;

                    // If too many missed claims, penalize character
                    if (missedClaims[_tokenId] >= maxMissedClaims) {
                        emit DripBurned(_tokenId, dripAmount);

                        // Reduce character attributes
                        CharacterAttributes storage char = nftHolderAttributes[_tokenId];
                        if (char.health > 10) char.health -= 10;
                        if (char.happiness > 10) char.happiness -= 10;
                        emit CharacterUpdated(_tokenId, char);
                    }
                }
            }
        }
    }

    function getMinterAddressAsString() public view returns (string memory) {
        return addressToString(msg.sender);
    }

    /**
     * @dev Converts an address to a string.
     * @param _addr The address to convert.
     * @return The address as a string.
     */
    function addressToString(address _addr) public pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(_addr);
        bytes memory str = new bytes(42); // 2 characters for '0x', and 40 characters for the address
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(value[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(value[i] & 0x0f))];
        }
        return string(str);
    }

    function updateCharacterAttributes(uint256 tokenId, CharacterAttributes calldata attributes) external onlyOwner {
        require(_exists(tokenId), "Nonexistent token");
        nftHolderAttributes[tokenId] = attributes;
        emit CharacterUpdated(tokenId, attributes);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        CharacterAttributes memory charAttributes = nftHolderAttributes[tokenId];

        // Get the VOXEL balance of the token owner
        uint256 voxelBalance = getVoxelBalance(tokenId);

        string memory json = Base64.encode(
            bytes(
                abi.encodePacked(
                    '{"name":"',
                    charAttributes.name,
                    '","description":"This is your beta character in the VoxelVerseMC game!","image":"',
                    charAttributes.imageURI,
                    '","attributes":',
                    _formatAttributes(charAttributes, voxelBalance),
                    "}"
                )
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", json));
    }

    function _formatAttributes(CharacterAttributes memory charAttributes, uint256 voxelBalance)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "[",
                _formatAttribute("Happiness", charAttributes.happiness),
                ",",
                _formatAttribute("Health", charAttributes.health),
                ",",
                _formatAttribute("Hunger", charAttributes.hunger),
                ",",
                _formatAttribute("XP", charAttributes.xp),
                ",",
                _formatAttribute("Days", charAttributes.daysSurvived),
                ",",
                _formatAttribute("Level", charAttributes.characterLevel),
                ",",
                _formatAttribute("Heat", charAttributes.heat),
                ",",
                _formatAttribute("Thirst", charAttributes.thirst),
                ",",
                _formatAttribute("VOXEL Balance", voxelBalance / 10 ** 18), // Convert from wei to whole tokens
                "]"
            )
        );
    }

    function _formatAttribute(string memory traitType, uint256 value) private pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":', value.toString(), "}"));
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Enforce transfer restrictions
        if (from != address(0) && !transfersEnabled) {
            revert TransfersDisabled();
        }

        return super._update(to, tokenId, auth);
    }

    // Check missed claims for a token
    function getMissedClaims(uint256 _tokenId) external view returns (uint256, uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);

        // Calculate how many days have passed since last claim
        uint256 daysSinceLastClaim = (block.timestamp - lastDripClaim[_tokenId]) / dripCooldown;

        // If it's been more than 1 day, they've missed some claims
        if (daysSinceLastClaim > 1) {
            uint256 currentMissed = missedClaims[_tokenId];
            uint256 additionalMissed = daysSinceLastClaim - 1;
            return (currentMissed, additionalMissed);
        }

        return (missedClaims[_tokenId], 0);
    }
}
