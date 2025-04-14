// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Voxel
 * @dev ERC20 token with capped supply, burnable functionality, pause control, and ownership access control.
 */
contract Voxel is ERC20Capped, ERC20Burnable, Pausable, Ownable {
    event Burned(address indexed account, uint256 amount);

    /**
     * @dev Constructor that mints the total supply to the deployer and sets the cap.
     */
    constructor() ERC20("Voxel", "VXL") ERC20Capped(21_000_000 * 10 ** 18) Ownable(msg.sender) {
        _mint(msg.sender, cap());
    }

    /**
     * @dev Override burn to include pause protection and emit a custom Burned event.
     */
    function burn(uint256 amount) public override whenNotPaused {
        super.burn(amount);
        emit Burned(msg.sender, amount);
    }

    /**
     * @dev Override burnFrom to include pause protection and emit a custom Burned event.
     */
    function burnFrom(address account, uint256 amount) public override whenNotPaused {
        super.burnFrom(account, amount);
        emit Burned(account, amount);
    }

    /**
     * @dev Pause all token transfers and burns.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause all token transfers and burns.
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    /**
     * @dev Override internal update hook to respect paused state and capped logic.
     */
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        require(!paused(), "Voxel: paused");
        super._update(from, to, value);
    }
}
