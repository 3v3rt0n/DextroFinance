pragma solidity 0.6.12;

interface IMoneyPot {
    function isDividendsToken(address _tokenAddr) external view returns (bool);
    function getRegisteredTokenLength() external view returns (uint256);
    function depositRewards(address _token, uint256 _amount) external;
    function getRegisteredToken(uint256 index) external view returns (address);
    function updateSRadsHolder(address _sRadsHolder) external;
}
