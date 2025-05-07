// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VoxelItems} from "./VoxelItems.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ActionManager} from "./ActionManager.sol";
import {Base64} from "./libraries/Base64.sol";
import {ClaimManager} from "./ClaimManager.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

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
error CharacterIsDead(uint256 tokenId);
error EmergencyModeNotActive();
error WithdrawalTooSoon(uint256 lastWithdrawal, uint256 cooldown, uint256 currentTime);
error WithdrawalAmountExceedsEntitlement(uint256 requested, uint256 entitled);
error XPClaimCooldown();
error XPDailyCapExceeded();
error AddressAlreadyHasNFT();
error TokenTransferFailed();
error InsufficientTokenBalanceVC();

contract VoxelVerseMC is ERC721, Ownable, Pausable, ReentrancyGuard, AccessControl, ClaimManager, ActionManager {
    using Strings for uint256;

    //VoxelItems public itemContract;

    address public trustedSigner;
    mapping(address => uint256) public actionNonces;
    mapping(address => uint256[]) private _ownedTokens;

    bool public emergencyModeActive = false;
    uint256 public emergencyWithdrawalCooldown = 1 days;
    mapping(address => uint256) public lastEmergencyWithdrawal;
    mapping(address => uint256) public totalEmergencyWithdrawn;

    bytes32 public constant EDITOR_ROLE = keccak256("EDITOR_ROLE");

    string constant DEFAULT_IMAGE_URI =
        "https://harlequin-leading-egret-2.mypinata.cloud/ipfs/Qmd7NWbw2JdUqnJk7rg1w2X79L36dbrbQ5QbESVzHYt3SH";

    IERC20 public tokenAddress;
    uint256 public dripAmount;

    bool public transfersEnabled = false;
    uint256 public reviveCost = 10 * 10 * 1e18;
    uint256 public maxVoucherExpiry = 1 days;
    uint256 public mintCost = 1000 * 1e18;

    uint256 public dripCooldown = 1 days;
    uint256 public claimWindow = 1 days;

    /// @notice how much to subtract from dripAmount per full missed day
    uint256 public decayRate = 1 * 1e18;

    uint256 private tokenId;
    uint256 public constant FREE_MINT_LIMIT = 250;
    uint256 public constant MINT_PRICE = 1000 * 1e18;
    uint256 public constant REVIVE_COST = 10 * 10 * 1e18;

    /// @notice Minimum time between two XP claims on the same character
    uint256 public xpClaimCooldown = 0;

    /// @notice Maximum XP a character can claim in a single 24-hour period
    uint256 public xpCapPerDay = 100;

    /// @notice Last timestamp at which each token claimed XP
    mapping(uint256 => uint256) public xpLastClaimTimestamp;

    /// @notice Day index (unix days) at which we last reset the daily counter
    mapping(uint256 => uint256) public xpLastClaimDay;

    /// @notice XP already claimed by each token during the current day
    mapping(uint256 => uint256) public xpClaimedToday;

    mapping(uint256 => uint256) public deathTimestamps;
    uint256 public reviveCooldown = 1 hours;

    struct CharacterAttributes {
        string name;
        string imageURI;
        uint16 happiness;
        uint16 thirst;
        uint16 hunger;
        uint16 xp;
        uint16 daysSurvived;
        uint16 characterLevel;
        uint16 health;
        uint16 heat;
    }

    mapping(uint256 => uint256) public lastDripClaim;
    mapping(uint256 => CharacterAttributes) public nftHolderAttributes;
    mapping(uint256 => bool) private _tokenMinted;
    mapping(address => bool) private _addressHasNFT;
    mapping(uint256 => bool) private _tokenExists;
    mapping(uint256 => uint256) public missedClaims;

    uint256 public maxMissedClaims = 3;

    event DripBurned(uint256 indexed tokenId, uint256 amount);
    event CharacterUpdated(uint256 tokenId, CharacterAttributes attributes);
    event CharacterNFTMinted(address indexed recipient, uint256 indexed tokenId, CharacterAttributes attributes);
    event DripClaimed(address indexed claimer, uint256 indexed tokenId, uint256 amount);
    event StartingTokensIssued(address indexed recipient, uint256 amount);
    event ContractRefilled(uint256 amount, uint256 newBalance);
    event PaidMint(address indexed minter, uint256 tokenId, uint256 price);
    event CharacterBurned(uint256 indexed tokenId);
    event CharacterRevived(uint256 indexed tokenId, address indexed user);
    event CharacterDied(uint256 indexed tokenId, uint256 timestamp);
    event EmergencyModeActivated(uint256 timestamp);
    event EmergencyModeDeactivated(uint256 timestamp);
    event EmergencyWithdrawal(address indexed user, uint256 amount, uint256 timestamp);

    constructor(address _tokenAddress, uint256 _dripAmount) ERC721("VoxelVerseMC", "VVMC") Ownable(msg.sender) {
        if (_tokenAddress == address(0)) revert InvalidAddress(_tokenAddress);
        tokenAddress = IERC20(_tokenAddress);
        dripAmount = _dripAmount;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EDITOR_ROLE, msg.sender);
    }

    modifier onlyEditor() {
        require(hasRole(EDITOR_ROLE, msg.sender), "Not editor");
        _;
    }

    function setDripAmount(uint256 _dripAmount) external onlyOwner {
        dripAmount = _dripAmount;
    }

    function setDripCooldown(uint256 _dripCooldown) external onlyOwner {
        dripCooldown = _dripCooldown;
    }

    function setMaxMissedClaims(uint256 _maxMissedClaims) external onlyOwner {
        maxMissedClaims = _maxMissedClaims;
    }

    function setTransfersEnabled(bool _enabled) external onlyOwner {
        transfersEnabled = _enabled;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function hashAction(Action calldata action) public pure override(ClaimManager, ActionManager) returns (bytes32) {
        return ClaimManager.hashAction(action); // Use ClaimManager version
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function mintCharacterNFT() external whenNotPaused nonReentrant {
        if (_addressHasNFT[msg.sender]) revert AddressAlreadyHasNFT(msg.sender);

        uint256 id = tokenId;
        if (_tokenMinted[id]) revert CharacterAlreadyMinted(id);

        if (id >= FREE_MINT_LIMIT) {
            if (tokenAddress.balanceOf(msg.sender) < MINT_PRICE) revert InsufficientTokenBalanceVC();
            if (!tokenAddress.transferFrom(msg.sender, address(this), MINT_PRICE)) revert TokenTransferFailed();
            emit PaidMint(msg.sender, id, MINT_PRICE);
        }

        _checkSufficientBalance(10 ether);

        _safeMint(msg.sender, id);
        _ownedTokens[msg.sender].push(id);

        nftHolderAttributes[id] = CharacterAttributes({
            name: addressToString(msg.sender),
            imageURI: DEFAULT_IMAGE_URI,
            happiness: 50,
            thirst: 100,
            hunger: 100,
            xp: 1,
            daysSurvived: 1,
            characterLevel: 1,
            health: 100,
            heat: 50
        });

        _tokenMinted[id] = true;
        _addressHasNFT[msg.sender] = true;
        _tokenExists[id] = true;
        lastDripClaim[id] = block.timestamp;

        if (!tokenAddress.transfer(msg.sender, 10 ether)) revert TokenTransferFailed();
        emit StartingTokensIssued(msg.sender, 10 ether);
        emit CharacterNFTMinted(msg.sender, id, nftHolderAttributes[id]);

        tokenId++;
    }

    function claimDrip(uint256 _tokenId) external whenNotPaused nonReentrant {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        if (msg.sender != ownerOf(_tokenId)) revert NotTokenOwner(msg.sender, _tokenId, ownerOf(_tokenId));

        CharacterAttributes storage char = nftHolderAttributes[_tokenId];
        if (char.health == 0) revert CharacterIsDead(_tokenId);

        uint256 last = lastDripClaim[_tokenId];
        uint256 nowTime = block.timestamp;
        uint256 elapsed = nowTime - last;

        if (elapsed < dripCooldown) revert TooEarlyToClaim(_tokenId, last + dripCooldown);

        uint256 periods = elapsed / dripCooldown;
        uint256 missed = periods > 1 ? periods - 1 : 0;

        missedClaims[_tokenId] = missed;
        lastDripClaim[_tokenId] = last + (periods * dripCooldown);

        if (missed > maxMissedClaims) {
            if (char.health > 10) char.health -= 10;
            if (char.happiness > 10) char.happiness -= 10;
            emit CharacterUpdated(_tokenId, char);
            emit DripBurned(_tokenId, dripAmount);
        }

        uint256 decay = decayRate * missed;
        uint256 reward = decay >= dripAmount ? 0 : dripAmount - decay;

        if (reward > 0) {
            _checkSufficientBalance(reward);
            if (!tokenAddress.transfer(msg.sender, reward)) revert TokenTransferFailed();
        }

        emit DripClaimed(msg.sender, _tokenId, reward);
    }

    function getHealth(uint256 _tokenId) external view returns (uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        return nftHolderAttributes[_tokenId].health;
    }

    function getNextClaimWindow(uint256 _tokenId) external view returns (uint256 start, uint256 end) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        uint256 next = lastDripClaim[_tokenId] + dripCooldown;
        return (next, next + claimWindow);
    }

    function burnCharacter(uint256 _tokenId) external {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        address tokenOwner = ownerOf(_tokenId);
        if (msg.sender != tokenOwner && msg.sender != owner()) revert NotTokenOwner(msg.sender, _tokenId, tokenOwner);

        _burn(_tokenId);
        removeOwnedToken(tokenOwner, _tokenId);
        delete nftHolderAttributes[_tokenId];
        delete _tokenExists[_tokenId];
        delete lastDripClaim[_tokenId];
        delete missedClaims[_tokenId];
        emit CharacterBurned(_tokenId);
    }

    function removeOwnedToken(address owner, uint256 tokenIdToRemove) internal {
        uint256[] storage tokens = _ownedTokens[owner];
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == tokenIdToRemove) {
                tokens[i] = tokens[tokens.length - 1]; // swap with last
                tokens.pop(); // remove last
                break;
            }
        }
    }

    function withdrawTokens(uint256 amount) external onlyOwner {
        _checkSufficientBalance(amount);
        bool success = tokenAddress.transfer(owner(), amount);
        if (!success) revert TokenTransferFailed();
    }

    function _applyCharacterPenalty(uint256 _tokenId) internal {
        CharacterAttributes storage char = nftHolderAttributes[_tokenId];
        if (char.health > 10) char.health -= 10;
        if (char.happiness > 10) char.happiness -= 10;
        emit DripBurned(_tokenId, dripAmount);
        emit CharacterUpdated(_tokenId, char);
    }

    function updateCharacterAttributes(uint256 _tokenId, CharacterAttributes calldata attributes) external onlyEditor {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        nftHolderAttributes[_tokenId] = attributes;
        emit CharacterUpdated(_tokenId, attributes);
    }

    function _exists(uint256 _tokenId) internal view returns (bool) {
        return _tokenExists[_tokenId];
    }

    function _checkSufficientBalance(uint256 amount) internal view {
        uint256 contractBalance = tokenAddress.balanceOf(address(this));
        if (contractBalance < amount) revert InsufficientContractBalance(amount, contractBalance);
    }

    function _update(address to, uint256 tokenId_, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId_);
        if (from != address(0) && !transfersEnabled) revert TransfersDisabled();
        return super._update(to, tokenId_, auth);
    }

    function refillContract(uint256 amount) external onlyOwner {
        bool success = tokenAddress.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TokenTransferFailed();
        emit ContractRefilled(amount, tokenAddress.balanceOf(address(this)));
    }

    function tokenURI(uint256 tokenId_) public view override returns (string memory) {
        require(_exists(tokenId_), "ERC721Metadata: URI query for nonexistent token");

        // owner and base attributes
        address owner = ownerOf(tokenId_);
        CharacterAttributes memory char = nftHolderAttributes[tokenId_];
        uint256 voxelBalance = tokenAddress.balanceOf(owner);

        // choose display name: tag if set, otherwise raw address
        string memory displayName = addressToString(owner);

        // build JSON, substituting displayName for char.name
        string memory json = Base64.encode(
            bytes(
                abi.encodePacked(
                    '{"name":"',
                    displayName,
                    '","description":"This is your beta character in the VoxelVerseMC game!","image":"',
                    char.imageURI,
                    '","attributes":',
                    _formatAttributes(char, voxelBalance),
                    "}"
                )
            )
        );
        return string(abi.encodePacked("data:application/json;base64,", json));
    }

    function _formatAttributes(CharacterAttributes memory char, uint256 voxelBalance)
        private
        pure
        returns (string memory)
    {
        return string(
            abi.encodePacked(
                "[",
                _formatAttribute("Happiness", char.happiness),
                ",",
                _formatAttribute("Health", char.health),
                ",",
                _formatAttribute("Hunger", char.hunger),
                ",",
                _formatAttribute("XP", char.xp),
                ",",
                _formatAttribute("Days", char.daysSurvived),
                ",",
                _formatAttribute("Level", char.characterLevel),
                ",",
                _formatAttribute("Heat", char.heat),
                ",",
                _formatAttribute("Thirst", char.thirst),
                ",",
                _formatAttribute("VOXEL Balance", voxelBalance / 1e18),
                "]"
            )
        );
    }

    function _formatAttribute(string memory traitType, uint256 value) private pure returns (string memory) {
        return string(abi.encodePacked('{"trait_type":"', traitType, '","value":', value.toString(), "}"));
    }

    function addressToString(address _addr) public pure returns (string memory) {
        // check is gamer tag exist
        // if exist convert public address to gamer tag id and return as string.
        bytes memory alphabet = "0123456789abcdef";
        bytes20 value = bytes20(_addr);
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function getRemainingFreeMints() public view returns (uint256) {
        return tokenId >= FREE_MINT_LIMIT ? 0 : FREE_MINT_LIMIT - tokenId;
    }

    function getCurrentMintPrice() public view returns (uint256) {
        return tokenId < FREE_MINT_LIMIT ? 0 : MINT_PRICE;
    }

    function timeToNextDrip(uint256 _tokenId) public view returns (uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);

        uint256 timeSinceLastClaim = block.timestamp - lastDripClaim[_tokenId];

        if (timeSinceLastClaim >= dripCooldown) {
            return 0;
        }

        return dripCooldown - timeSinceLastClaim;
    }

    function getMissedClaims(uint256 _tokenId) public view returns (uint256, uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);

        uint256 daysSinceLastClaim = (block.timestamp - lastDripClaim[_tokenId]) / dripCooldown;

        if (daysSinceLastClaim > 1) {
            uint256 currentMissed = missedClaims[_tokenId];
            uint256 additionalMissed = daysSinceLastClaim - 1;
            return (currentMissed, additionalMissed);
        }

        return (missedClaims[_tokenId], 0);
    }

    function getVoxelBalance(uint256 _tokenId) public view returns (uint256) {
        if (!_exists(_tokenId)) revert TokenDoesNotExist(_tokenId);
        address owner = ownerOf(_tokenId);
        return tokenAddress.balanceOf(owner);
    }

    function transferCharacter(address to, uint256 chracterId) external {
        safeTransferFrom(msg.sender, to, chracterId);
    }

    function consumeAction(Action calldata action, bytes calldata signature) external {
        require(action.user == msg.sender, "Not sender");
        require(action.nonce == nonces[msg.sender], "Invalid nonce");
        require(verifyActionSignature(action, signature, msg.sender), "Invalid signature");

        nonces[msg.sender]++; // Consume nonce
            // Process the action...
    }

    function claimXP(ClaimManager.XPClaim calldata claim, bytes calldata sig) external {
        require(ClaimManager.verifyXPClaim(claim, sig, trustedSigner), "Invalid signature");
        require(claim.nonce == nonces[claim.user], "Invalid nonce");

        // Apply XP, etc.
        nonces[claim.user]++;
    }

    function setTrustedSigner(address signer) external onlyOwner {
        require(signer != address(0), "Invalid signer");
        trustedSigner = signer;
    }

    function claimXPReward(ClaimManager.XPClaim calldata claim, bytes calldata sig) external {
        uint256 tokenId = claim.tokenId;

        useXPClaim(claim, sig, trustedSigner);

        uint256 ts = block.timestamp;
        if (xpClaimCooldown > 0 && ts < xpLastClaimTimestamp[tokenId] + xpClaimCooldown) {
            revert XPClaimCooldown();
        }

        uint256 today = ts / 1 days;
        if (xpLastClaimDay[tokenId] < today) {
            xpLastClaimDay[tokenId] = today;
            xpClaimedToday[tokenId] = 0;
        }

        uint256 claimed = xpClaimedToday[tokenId] + claim.xpAmount;
        if (claimed > xpCapPerDay) revert XPDailyCapExceeded();

        xpClaimedToday[tokenId] = claimed;
        xpLastClaimTimestamp[tokenId] = ts;

        CharacterAttributes storage c = nftHolderAttributes[tokenId];
        unchecked {
            c.xp = uint16(uint256(c.xp) + claim.xpAmount);
        }

        emit CharacterUpdated(tokenId, c);
    }

    function useAction(ActionManager.Action calldata action, bytes calldata sig, address trustedSigner)
        internal
        override
    {
        require(action.user == msg.sender, "Not your action");
        require(action.nonce == actionNonces[msg.sender], "Invalid nonce");
        require(verifyActionSignature(action, sig, trustedSigner), "Bad signature");
        actionNonces[msg.sender]++;
    }

    function reviveCharacter(uint256 tokenId) external nonReentrant {
        if (!_exists(tokenId)) revert TokenDoesNotExist(tokenId);
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(msg.sender, tokenId, ownerOf(tokenId));

        CharacterAttributes storage char = nftHolderAttributes[tokenId];
        require(char.health == 0, "Character is not dead");

        _checkSufficientBalance(reviveCost);

        bool success = tokenAddress.transferFrom(msg.sender, address(this), reviveCost);
        if (!success) revert TokenTransferFailed();

        // Reset attributes
        char.health = 100;
        char.happiness = 50;
        char.thirst = 100;
        char.hunger = 100;

        emit CharacterUpdated(tokenId, char);
        emit CharacterRevived(tokenId, msg.sender);
    }

    function setReviveCost(uint256 _newCost) external onlyOwner {
        reviveCost = _newCost;
    }

    function exposedHashTypedDataV4(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }

    /// @notice Update the maximum expiry window for vouchers (e.g., 86400 = 1 day)
    function setMaxVoucherExpiry(uint256 newExpiry) external onlyOwner {
        require(newExpiry > 0, "Expiry must be > 0");
        maxVoucherExpiry = newExpiry;
    }

    /// @notice Update the cost to mint (for paid mints)
    function setMintCost(uint256 newCost) external onlyOwner {
        require(newCost > 0, "Cost must be > 0");
        mintCost = newCost;
    }

    function mintCharacterWithVoucher(MintVoucher calldata v, bytes calldata sig) external whenNotPaused {
        useMintVoucher(v, sig, trustedSigner);
        _mintCharacter(msg.sender);
    }

    function getMaxVoucherExpiry() public view override returns (uint256) {
        return maxVoucherExpiry;
    }

    function _mintCharacter(address user) internal {
        if (_addressHasNFT[user]) revert AddressAlreadyHasNFT(user);

        uint256 newItemId = tokenId;
        if (_tokenMinted[newItemId]) revert CharacterAlreadyMinted(newItemId);

        CharacterAttributes memory attributes = CharacterAttributes({
            name: addressToString(user),
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

        _safeMint(user, newItemId);
        _ownedTokens[user].push(newItemId);
        nftHolderAttributes[newItemId] = attributes;
        _tokenMinted[newItemId] = true;
        _addressHasNFT[user] = true;
        _tokenExists[newItemId] = true;
        lastDripClaim[newItemId] = block.timestamp;

        bool granted = tokenAddress.transfer(user, 10 * 1e18);
        if (!granted) revert TokenTransferFailed();

        emit StartingTokensIssued(user, 10 * 1e18);
        emit CharacterNFTMinted(user, newItemId, attributes);
        tokenId++;
    }

    function mintCharacter() external whenNotPaused nonReentrant {
        if (_addressHasNFT[msg.sender]) revert AddressAlreadyHasNFT(msg.sender);

        if (tokenId < FREE_MINT_LIMIT) revert("Free mints still available; use mintCharacterNFT()");

        uint256 userBalance = tokenAddress.balanceOf(msg.sender);
        if (userBalance < mintCost) revert InsufficientTokenBalance(msg.sender, mintCost, userBalance);

        bool paid = tokenAddress.transferFrom(msg.sender, address(this), mintCost);
        if (!paid) revert TokenTransferFailed();

        emit PaidMint(msg.sender, tokenId, mintCost);

        _mintCharacter(msg.sender);
    }

    // Helper function to count user's NFTs
    function getUserNFTCount(address user) public view returns (uint256) {
        return _ownedTokens[user].length;
    }

    function setXpClaimCooldown(uint256 _secs) external onlyOwner {
        xpClaimCooldown = _secs;
    }

    function setXpCapPerDay(uint256 _cap) external onlyOwner {
        xpCapPerDay = _cap;
    }

    /// @notice Adjust per-day decay in TOKEN units
    function setDecayRate(uint256 _rate) external onlyOwner {
        decayRate = _rate;
    }
}
