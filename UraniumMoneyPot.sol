pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "./interfaces/IMoneyPot.sol";

/*
* This contract is used to collect sRADS stacking dividends from fee (like swap, deposit on pools or farms)
*/
contract UraniumMoneyPot is Ownable, IMoneyPot {
    using SafeBEP20 for IBEP20;
    using SafeMath for uint256;


    struct TokenPot {
        uint256 tokenAmount; // Total amount distributing over 1 cycle (updateMoneyPotPeriodNbBlocks)
        uint256 accTokenPerShare; // Amount of dividends per Share
        uint256 lastRewardBlock; // last data update
        uint256 lastUpdateTokenPotBlocks; // last cycle update for this token
    }

    struct UserInfo {
        uint256 rewardDept;
        uint256 pending;
    }

    IBEP20 public sRads;

    uint256 public updateMoneyPotPeriodNbBlocks;
    uint256 public lastUpdateMoneyPotBlocks;
    uint256 public startBlock; // Start block for dividends distribution (first cycle the current money pot will be empty)

    // _token => user => rewardsDebt / pending
    mapping(address => mapping (address => UserInfo)) public sRadsHoldersRewardsInfo;
    // user => LastSRadsBalanceSaved
    mapping (address => uint256) public sRadsHoldersInfo;

    address[] public registeredToken; // List of all token that will be distributed as dividends. Should never be too weight !
    mapping (address => bool )  public tokenInitialized; // List of token already added to registeredToken

    // addressWithoutReward is a map containing each address which are not going to get rewards
    // At least, it will include the masterChef address as masterChef minting continuously sRADS for rewards on RADS pair pool.
    // We can add later LP contract if someone initialized sRADS LP
    // Those contracts are included as holders on sRADS
    // All dividends attributed to those addresses are going to be added to the "reserveTokenAmount"
    mapping (address => bool) addressWithoutReward;
    // address of the feeManager which is allow to add dividends to the pendingTokenPot
    address public feeManager;

    mapping (address => TokenPot) private _distributedMoneyPot; // Current MoneyPot
    mapping (address => uint256 ) public pendingTokenAmount; // Pending amount of each dividends token that will be distributed in next cycle
    mapping (address => uint256) public reserveTokenAmount; // Bonus which is used to add more dividends in the pendingTokenAmount

    uint256 public lastSRadsSupply; // Cache the last totalSupply of sRads

    constructor (IBEP20 _sRads, address _feeManager, address _masterUranium, uint256 _startBlock, uint256 _initialUpdateMoneyPotPeriodNbBlocks) public{
        updateMoneyPotPeriodNbBlocks = _initialUpdateMoneyPotPeriodNbBlocks;
        startBlock = _startBlock;
        lastUpdateMoneyPotBlocks = _startBlock;
        sRads = _sRads;
        addressWithoutReward[_masterUranium] = true;
        feeManager = _feeManager;
    }

    function getRegisteredToken(uint256 index) external virtual override view returns (address){
        return registeredToken[index];
    }

    function distributedMoneyPot(address _token) external view returns (uint256 tokenAmount, uint256 accTokenPerShare, uint256 lastRewardBlock ){
        return (
            _distributedMoneyPot[_token].tokenAmount,
            _distributedMoneyPot[_token].accTokenPerShare,
            _distributedMoneyPot[_token].lastRewardBlock
        );
    }

    function isDividendsToken(address _tokenAddr) external virtual override view returns (bool){
        return tokenInitialized[_tokenAddr];
    }


    function updateAddressWithoutReward(address _contract, bool _unattributeDividends) external onlyOwner {
        addressWithoutReward[_contract] = _unattributeDividends;
    }

    function updateFeeManager(address _feeManager) external onlyOwner{
        // Allow us to update the feeManager contract => Can be upgraded if needed
        feeManager = _feeManager;
    }

    function getRegisteredTokenLength() external virtual override view returns (uint256){
        return registeredToken.length;
    }

    function getTokenAmountPotFromMoneyPot(address _token) external view returns (uint256 tokenAmount){
        return _distributedMoneyPot[_token].tokenAmount;
    }

    // Amount of dividends in a specific token distributed at each block during the current cycle (=updateMoneyPotPeriodNbBlocks)
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
        if(_from >= _to){
            return 0;
        }
        return _to.sub(_from);
    }

    /*
    Update current dividends for specific token
    */
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

    /*
    Used by front-end to display user's pending rewards that he can harvest
    */
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


    /*
    Update tokenPot, user's sRads balance (cache) and pending dividends
    */
    function updateSRadsHolder(address _sRadsHolder) external virtual override {
        uint256 holderPreviousSRadsAmount = sRadsHoldersInfo[_sRadsHolder];
        uint256 holderBalance = sRads.balanceOf(_sRadsHolder);
        uint256 length = registeredToken.length;
        for (uint256 index = 0; index < length; ++index) {
            _updateTokenPot(registeredToken[index]);
            TokenPot storage tokenPot = _distributedMoneyPot[registeredToken[index]];
            if(holderPreviousSRadsAmount > 0 && tokenPot.accTokenPerShare > 0){
                uint256 pending = holderPreviousSRadsAmount.mul(tokenPot.accTokenPerShare).div(1e12).sub(sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].rewardDept);
                if(pending > 0) {
                    if (addressWithoutReward[_sRadsHolder]) {
                        if(sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].pending > 0){
                            pending = pending.add(sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].pending);
                            sRadsHoldersRewardsInfo[registeredToken[index]][_sRadsHolder].pending = 0;
                        }
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

    /*
    * Allow user to harvest their pending dividends
    */
    function harvestReward(address _sRadsHolder, address _token) public {
        uint256 holderBalance = sRadsHoldersInfo[_sRadsHolder];
        _updateTokenPot(_token);
        TokenPot storage tokenPot = _distributedMoneyPot[_token];
        if(holderBalance > 0 && tokenPot.accTokenPerShare > 0){
            uint256 pending = holderBalance.mul(tokenPot.accTokenPerShare).div(1e12).sub(sRadsHoldersRewardsInfo[_token][_sRadsHolder].rewardDept);
            if(pending > 0) {
                if (addressWithoutReward[_sRadsHolder]) {
                        if(sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending > 0){
                            pending = pending.add(sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending);
                            sRadsHoldersRewardsInfo[_token][_sRadsHolder].pending = 0;
                        }
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
    function depositRewards(address _token, uint256 _amount) external virtual override{
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

    /*
    * Allow token address to be distributed as dividends to sRADS holder
    */
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

    /*
    Remove token address to be distributed as dividends to sRADS holder
    */
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

    /*
     Used by front-end to get the next moneyPot cycle update
     */
    function nextMoneyPotUpdateBlock() external view returns (uint256){
        return lastUpdateMoneyPotBlocks.add(updateMoneyPotPeriodNbBlocks);
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
}
