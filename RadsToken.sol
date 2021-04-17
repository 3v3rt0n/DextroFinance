pragma solidity 0.6.12;

import "./libs/UraniumBEP20.sol";

contract RadsToken is UraniumBEP20("Uranium U92", "U92") {

    address public sRads;

    /*
     * @dev Throws if called by any account other than the owner or sRads
     */
    modifier onlyOwnerOrSRads() {
        require(isOwner() || isSRads(), "caller is not the owner or sRads");
        _;
    }

    /**
     * @dev Returns true if the caller is the current owner.
     */
    function isOwner() public view returns (bool) {
        return msg.sender == owner();
    }

    /**
     * @dev Returns true if the caller is sRads contracts.
     */
    function isSRads() internal view returns (bool) {
        return msg.sender == address(sRads);
    }

    function setupSRads(address _sRads) external onlyOwner{
        sRads = _sRads;
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterUranium).
    function mint(address _to, uint256 _amount) external virtual override onlyOwnerOrSRads  {
        _mint(_to, _amount);
    }


    /// @dev overrides transfer function to meet tokenomics of RADS
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        require(amount > 0, "amount 0");
        if (recipient == BURN_ADDRESS) {
            super._burn(sender, amount);
        } else {
            // 2% of every transfer burnt
            uint256 burnAmount = amount.mul(2).div(100);
            // 98% of transfer sent to recipient
            uint256 sendAmount = amount.sub(burnAmount);
            require(amount == sendAmount + burnAmount, "RADS::transfer: Burn value invalid");

            super._burn(sender, burnAmount);
            super._transfer(sender, recipient, sendAmount);
            amount = sendAmount;
        }
    }

}
