pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "./SRadsToken.sol";

/*
* This contract is used to collect sRADS stacking rewards from fee (like swap, deposit on pools or farms)
*/
contract UraniumMoneyPot is Ownable {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;


    struct TokenPot {
        uint256 tokenAmount;
        uint256 accTokenPerShare;
        uint256 lastRewardBlock;
        uint256 lastUpdateTokenPotBlocks;
    }

    struct UserInfo {
        uint256 rewardDept;
        uint256 pending;
    }

    SRadsToken public sRads;

    uint256 public updateMoneyPotPeriodNbBlocks;
    uint256 public lastUpdateMoneyPotBlocks;
    uint256 public startBlock;

    // _token => user => rewardsDebt / pending
    mapping(address => mapping (address => UserInfo)) public sRadsHoldersRewardsInfo;
    // user => LastSRadsAmountSaved
    mapping (address => uint256) public sRadsHoldersInfo;

    address[] public registeredToken; // Should never be too weight !
    mapping (address => bool )  public tokenInitialized;

    address public masterUranium;
    address public feeManager;

    mapping (address => TokenPot) private _distributedMoneyPot;
    mapping (address => uint256 ) public pendingTokenAmount;
    mapping (address => uint256) public reserveTokenAmount;

    uint256 public lastSRadsSupply;

    constructor (SRadsToken _sRads, address _feeManager, address _masterUranium, uint256 _startBlock, uint256 _initialUpdateMoneyPotPeriodNbBlocks) public{
        updateMoneyPotPeriodNbBlocks = _initialUpdateMoneyPotPeriodNbBlocks;
        startBlock = _startBlock;
        lastUpdateMoneyPotBlocks = _startBlock;
        sRads = _sRads;
        masterUranium = _masterUranium;
        feeManager = _feeManager;
    }

    function distributedMoneyPot(address _token) external view returns (uint256 tokenAmount, uint256 accTokenPerShare, uint256 lastRewardBlock ){
        return (
            _distributedMoneyPot[_token].tokenAmount,
            _distributedMoneyPot[_token].accTokenPerShare,
            _distributedMoneyPot[_token].lastRewardBlock
        );
    }

    function getRegisteredTokenLength() external view returns (uint256){
        return registeredToken.length;
    }

    function getTokenAmountPotFromMoneyPot(address _token) external view returns (uint256 tokenAmount){
        return _distributedMoneyPot[_token].tokenAmount;
    }

    function tokenPerBlock(address _token) external view returns (uint256){
        return _distributedMoneyPot[_token].tokenAmount.div(updateMoneyPotPeriodNbBlocks);
    }

    function massUpdateMoneyPot() public {
        uint256 length = registeredToken.length;
        for (uint256 index = 0; index < length; ++index) {
            _updateTokenPot(registeredToken[index]);
        }
    }

    function updateCurrentMoneyPot(address _token) external{
        _updateTokenPot(_token);
    }

    function getMultiplier(uint256 _from, uint256 _to) internal pure returns (uint256){
        return _to.sub(_from);
    }

    function _updateTokenPot(address _token) internal {
        TokenPot storage tokenPot = _distributedMoneyPot[_token];
        if (block.number <= tokenPot.lastRewardBlock) {
            return;
        }

        if (lastSRadsSupply == 0) {
            tokenPot.lastRewardBlock = block.number;
            return;
        }

        if (block.number >= tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks)){
            if(tokenPot.tokenAmount > 0){
                uint256 multiplier = getMultiplier(tokenPot.lastRewardBlock, tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks));
                uint256 tokenRewardsPerBlock = tokenPot.tokenAmount.div(updateMoneyPotPeriodNbBlocks);
                tokenPot.accTokenPerShare = tokenPot.accTokenPerShare.add(tokenRewardsPerBlock.mul(multiplier).mul(1e12).div(lastSRadsSupply));
            }
            tokenPot.tokenAmount = pendingTokenAmount[_token];
            pendingTokenAmount[_token] = 0;
            tokenPot.lastRewardBlock = tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks);
            tokenPot.lastUpdateTokenPotBlocks = tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks);
            lastUpdateMoneyPotBlocks = tokenPot.lastUpdateTokenPotBlocks;

            if (block.number >= tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks)){
//                _updateTokenPot(_token);
                // If something bad happen in blockchain and moneyPot aren't able to be updated since
                // return here, will allow us to re-call updatePool manually, instead of directly doing it recursively here
                // which can cause too much gas error and so break all the MP contract
                return;
            }
        }
        if(tokenPot.tokenAmount > 0){
            uint256 multiplier = getMultiplier(tokenPot.lastRewardBlock, block.number);
            uint256 tokenRewardsPerBlock = tokenPot.tokenAmount.div(updateMoneyPotPeriodNbBlocks);
            tokenPot.accTokenPerShare = tokenPot.accTokenPerShare.add(tokenRewardsPerBlock.mul(multiplier).mul(1e12).div(lastSRadsSupply));
        }

        tokenPot.lastRewardBlock = block.number;

        if (block.number >= tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks)){
            lastUpdateMoneyPotBlocks = tokenPot.lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks);
        }
    }

    function pendingTokenRewardsAmount(address _token, address _user) external view returns (uint256){

        if(lastSRadsSupply == 0){
            return 0;
        }

        uint256 accTokenPerShare = _distributedMoneyPot[_token].accTokenPerShare;
        uint256 tokenReward = _distributedMoneyPot[_token].tokenAmount.div(updateMoneyPotPeriodNbBlocks);
        uint256 lastRewardBlock = _distributedMoneyPot[_token].lastRewardBlock;
        uint256 lastUpdateTokenPotBlocks = _distributedMoneyPot[_token].lastUpdateTokenPotBlocks;
        if (block.number >= lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks)){
            accTokenPerShare = (accTokenPerShare.add(
                    tokenReward.mul(getMultiplier(lastRewardBlock, lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks))
                ).mul(1e12).div(lastSRadsSupply)));
            lastRewardBlock = lastUpdateTokenPotBlocks.add(updateMoneyPotPeriodNbBlocks);
            tokenReward = pendingTokenAmount[_token].div(updateMoneyPotPeriodNbBlocks);
        }

        if (block.number > lastRewardBlock && lastSRadsSupply != 0 && tokenReward > 0) {
            accTokenPerShare = accTokenPerShare.add(
                    tokenReward.mul(getMultiplier(lastRewardBlock, block.number)
                ).mul(1e12).div(lastSRadsSupply));
        }
        return (sRads.balanceOf(_user).mul(accTokenPerShare).div(1e12).sub(sRadsHoldersRewardsInfo[_token][_user].rewardDept))
                    .add(sRadsHoldersRewardsInfo[_token][_user].pending);
    }

    function updateSRadsHolder(address _sRadsHolder) external {
        uint256 holderPreviousSRadsAmount = sRadsHoldersInfo[_sRadsHolder];
        uint256 holderBalance = sRads.balanceOf(_sRadsHolder);
        uint256 length = registeredToken.length;
        for (uint256 index = 0; index < length; ++index) {
            _updateTokenPot(registeredToken[index]);
            TokenPot storage tokenPot = _distributedMoneyPot[registeredToken[index]];
            if(holderPreviousSRadsAmount > 0 && tokenPot.accTokenPerShare > 0){
                uint256 pending = holderPreviousSRadsAmount.mul(tokenPot.accTokenPerShare).div(1e12).sub(sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].rewardDept);
                if(pending > 0) {
                    if (_sRadsHolder == masterUranium) {
                        reserveTokenAmount[registeredToken[index]] = reserveTokenAmount[registeredToken[index]].add(pending);
                    }
                    else {
                        sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].pending = sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].pending.add(pending);
                    }
                }
            }
            sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].rewardDept = holderBalance.mul(tokenPot.accTokenPerShare).div(1e12);
        }
        if (holderPreviousSRadsAmount > 0){
            lastSRadsSupply = lastSRadsSupply.sub(holderPreviousSRadsAmount);
        }
        lastSRadsSupply = lastSRadsSupply.add(holderBalance);
        sRadsHoldersInfo[_sRadsHolder] = holderBalance;
    }

    function harvestRewards(address _sRadsHolder) external {
        uint256 length = registeredToken.length;

        for (uint256 index = 0; index < length; ++index) {
            harvestReward(_sRadsHolder, registeredToken[index]);
        }
    }

    function harvestReward(address _sRadsHolder, address _token) public {
        uint256 holderBalance = sRadsHoldersInfo[_sRadsHolder];
        _updateTokenPot(_token);
        TokenPot storage tokenPot = _distributedMoneyPot[_token];
        if(holderBalance > 0 && tokenPot.accTokenPerShare > 0){
            uint256 pending = holderBalance.mul(tokenPot.accTokenPerShare).div(1e12).sub(sRadsHoldersRewardsInfo[_token][_sRadsHolder].rewardDept);
            if(pending > 0) {
                if (_sRadsHolder == masterUranium) {
                    reserveTokenAmount[_token] = reserveTokenAmount[_token].add(pending);
                }
                else {
                    sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending = sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending.add(pending);
                }
            }
        }
        if ( sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending > 0 ){
            safeTokenTransfer(_token, _sRadsHolder, sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending);
            sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending = 0;
        }
        sRadsHoldersRewardsInfo[_token][_sRadsHolder].rewardDept = holderBalance.mul(tokenPot.accTokenPerShare).div(1e12);
    }

    /*
    * Used by feeManager contract to deposit rewards (collected from many sources)
    */
    function depositRewards(address _token, uint256 _amount) external{
        require(msg.sender == feeManager);
        massUpdateMoneyPot();

        IBEP20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        if(block.number < startBlock){
            reserveTokenAmount[_token] = reserveTokenAmount[_token].add(_amount);
        }
        else {
            pendingTokenAmount[_token] = pendingTokenAmount[_token].add(_amount);
        }
    }

    /*
    * Used by dev to deposit bonus rewards that can be added to pending pot at any time
    */
    function depositBonusRewards(address _token, uint256 _amount) external onlyOwner{
        IBEP20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        reserveTokenAmount[_token] = reserveTokenAmount[_token].add(_amount);
    }

    function addTokenToRewards(address _token) external onlyOwner{
        if (!tokenInitialized[_token]){
            registeredToken.push(_token);
            _distributedMoneyPot[_token].lastRewardBlock = lastUpdateMoneyPotBlocks > block.number ? lastUpdateMoneyPotBlocks : lastUpdateMoneyPotBlocks.add(updateMoneyPotPeriodNbBlocks);
            _distributedMoneyPot[_token].accTokenPerShare = 0;
            _distributedMoneyPot[_token].tokenAmount = 0;
            _distributedMoneyPot[_token].lastUpdateTokenPotBlocks = _distributedMoneyPot[_token].lastRewardBlock;
            tokenInitialized[_token] = true;
        }
    }

    function removeTokenToRewards(address _token) external onlyOwner{
        require(_distributedMoneyPot[_token].tokenAmount == 0, "cannot remove before end of distribution");
        if (tokenInitialized[_token]){
            uint256 length = registeredToken.length;
            uint256 indexToRemove = length; // If token not found web do not try to remove bad index
            for (uint256 index = 0; index < length; ++index) {
                if(registeredToken[index] == _token){
                    indexToRemove = index;
                    break;
                }
            }
            if(indexToRemove < length){ // Should never be false.. Or something wrong happened
                registeredToken[indexToRemove] = registeredToken[registeredToken.length-1];
                registeredToken.pop();
            }
            tokenInitialized[_token] = false;
            return;
        }
    }

    function nextMoneyPotUpdateBlock() external view returns (uint256){
        return lastUpdateMoneyPotBlocks.add(updateMoneyPotPeriodNbBlocks);
    }

    function setUpdateMoneyPotPeriodNbBlocks(uint256 _updateRewardsDelay) external onlyOwner{
        updateMoneyPotPeriodNbBlocks = _updateRewardsDelay.div(3 * 1 seconds);
    }

    function addToPendingFromReserveTokenAmount(address _token, uint256 _amount) external onlyOwner{
        require(_amount <= reserveTokenAmount[_token], "Insufficient amount");
        reserveTokenAmount[_token] = reserveTokenAmount[_token].sub(_amount);
        pendingTokenAmount[_token] = pendingTokenAmount[_token].add(_amount);
    }


    // Safe Token transfer function, just in case if rounding error causes pool to not have enough Tokens.
    function safeTokenTransfer(address _token, address _to, uint256 _amount) internal {
        IBEP20 token = IBEP20(_token);
        uint256 tokenBal = token.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > tokenBal) {
            transferSuccess = token.transfer(_to, tokenBal);
        } else {
            transferSuccess = token.transfer(_to, _amount);
        }
        require(transferSuccess, "safeSRadsTransfer: Transfer failed");
    }

// Only use in testnet !
//    function emergencyWithdraw(IBEP20 _token) external onlyOwner {
//        _token.safeTransfer(address(msg.sender), _token.balanceOf(address(this)));
//    }

}
