pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "./UraniumBonusAggregator.sol";
import "./libs/UraniumBEP20.sol";

// MasterUranium is the master of RADS and sRADS.
// The Ownership of this contract is going to be transferred to a timelock
contract MasterUranium is Ownable, IMasterBonus {
    using SafeMath for uint256;
    using SafeBEP20 for UraniumBEP20;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 amountWithBonus;
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of RADSs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accRadsPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accRadsPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 lpSupply;
        uint256 allocPoint;       // How many allocation points assigned to this pool. RADSs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that RADSs distribution occurs.
        uint256 accRadsPerShare; // Accumulated RADSs per share, times 1e12. See below.
        uint256 depositFeeBP;     // deposit Fee
        bool isSRadsRewards;
    }

    UraniumBonusAggregator public bonusAggregator;
    // The RADS TOKEN!
    UraniumBEP20 public rads;
    // The SRADS TOKEN!
    UraniumBEP20 public sRads;
    // Dev address.
    address public devaddr;
    // RADS tokens created per block.
    uint256 public radsPerBlock;
    // Deposit Fee address
    address public feeAddress;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when RADS mining starts.
    uint256 public immutable startBlock;

    // Initial emission rate: 1 RADS per block.
    uint256 public immutable initialEmissionRate;
    // Minimum emission rate: 0.5 RADS per block.
    uint256 public minimumEmissionRate = 500 finney;
    // Reduce emission every 2,8800 blocks ~ 24 hours.
    uint256 public immutable emissionReductionPeriodBlocks = 28800;
    // Emission reduction rate per period in basis points: 3%.
    uint256 public immutable emissionReductionRatePerPeriod = 300;
    // Last reduction period index
    uint256 public lastReductionPeriodIndex = 0;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);

    constructor(
        UraniumBEP20 _rads,
        UraniumBEP20 _srads,
        UraniumBonusAggregator _bonusAggregator,
        address _devaddr,
        address _feeAddress,
        uint256 _radsPerBlock,
        uint256 _startBlock
    ) public {
        rads = _rads;
        sRads = _srads;
        bonusAggregator = _bonusAggregator;
        devaddr = _devaddr;
        feeAddress = _feeAddress;
        radsPerBlock = _radsPerBlock;
        startBlock = _startBlock;
        initialEmissionRate = _radsPerBlock;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _rads,
            lpSupply: 0,
            allocPoint: 800,
            lastRewardBlock: _startBlock,
            accRadsPerShare: 0,
            depositFeeBP: 0,
            isSRadsRewards: false
        }));
        totalAllocPoint = 800;
    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "validatePool: pool exists?");
        _;
    }

    modifier onlyAggregator() {
        require(msg.sender == address(bonusAggregator), "Ownable: caller is not the owner");
        _;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function userBonus(uint256 _pid, address _user) public view returns (uint256){
        return bonusAggregator.getBonusOnFarmsForUser(_user, _pid);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint256 _depositFeeBP, bool _isSRadsRewards, bool _withUpdate) external onlyOwner {
        require(_depositFeeBP <= 400, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            lpSupply: 0,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRadsPerShare: 0,
            depositFeeBP : _depositFeeBP,
            isSRadsRewards: _isSRadsRewards
        }));
    }

    // Update the given pool's RADS allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint256 _depositFeeBP, bool _isSRadsRewards, bool _withUpdate) external onlyOwner {
        require(_depositFeeBP <= 400, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
        poolInfo[_pid].isSRadsRewards = _isSRadsRewards;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    // View function to see pending RADSs on frontend.
    function pendingRads(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRadsPerShare = pool.accRadsPerShare;
        uint256 lpSupply = pool.lpSupply;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 radsReward = multiplier.mul(radsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accRadsPerShare = accRadsPerShare.add(radsReward.mul(1e12).div(lpSupply));
        }
        uint256 userRewards = user.amountWithBonus.mul(accRadsPerShare).div(1e12).sub(user.rewardDebt);
        if(!pool.isSRadsRewards){
            // taking account of the 2% auto-burn
            userRewards = userRewards.mul(98).div(100);
        }
        return userRewards; // taking account of the 2% auto burn on rads
    }

    // Reduce emission rate based on configurations
    function updateEmissionRate() internal {
        if(startBlock > 0 && block.number <= startBlock){
            return;
        }
        if(radsPerBlock <= minimumEmissionRate){
            return;
        }

        uint256 currentIndex = block.number.sub(startBlock).div(emissionReductionPeriodBlocks);
        if (currentIndex <= lastReductionPeriodIndex) {
            return;
        }

        uint256 newEmissionRate = radsPerBlock;
        for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
            newEmissionRate = newEmissionRate.mul(1e4 - emissionReductionRatePerPeriod).div(1e4);
        }

        newEmissionRate = newEmissionRate < minimumEmissionRate ? minimumEmissionRate : newEmissionRate;
        if (newEmissionRate >= radsPerBlock) {
            return;
        }

        lastReductionPeriodIndex = currentIndex;
        uint256 previousEmissionRate = radsPerBlock;
        radsPerBlock = newEmissionRate;
        emit EmissionRateUpdated(msg.sender, previousEmissionRate, newEmissionRate);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePool(_pid) {
        updateEmissionRate();
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpSupply;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 radsReward = multiplier.mul(radsPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        uint256 devMintAmount = radsReward.div(10);
        rads.mint(devaddr, devMintAmount);
        if (pool.isSRadsRewards){
            sRads.mint(address(this), radsReward);
        }
        else{
            rads.mint(address(this), radsReward);
        }
        pool.accRadsPerShare = pool.accRadsPerShare.add(radsReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Allow UraniumBonusAggregator to add bonus on a single pool by id to a specific user
    function updateUserBonus(address _user, uint256 _pid, uint256 bonus) external virtual override validatePool(_pid) onlyAggregator{
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                if(pool.isSRadsRewards){
                    safeSRadsTransfer(_user, pending);
                }
                else{
                    safeRadsTransfer(_user, pending);
                }
            }
        }
        pool.lpSupply = pool.lpSupply.sub(user.amountWithBonus);
        user.amountWithBonus =  user.amount.mul(bonus.add(10000)).div(10000);
        pool.lpSupply = pool.lpSupply.add(user.amountWithBonus);
        user.rewardDebt = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12);
    }

    // Deposit LP tokens to MasterUranium for RADS allocation.
    function deposit(uint256 _pid, uint256 _amount) external validatePool(_pid) {
        address _user = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                if(pool.isSRadsRewards){
                    safeSRadsTransfer(_user, pending);
                }
                else{
                    safeRadsTransfer(_user, pending);
                }
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(_user), address(this), _amount);
            if (address(pool.lpToken) == address(rads)) {
                uint256 transferTax = _amount.mul(2).div(100);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
                uint256 _bonusAmount = _amount.sub(depositFee).mul(userBonus(_pid, _user).add(10000)).div(10000);
                user.amountWithBonus = user.amountWithBonus.add(_bonusAmount);
                pool.lpSupply = pool.lpSupply.add(_bonusAmount);
            } else {
                user.amount = user.amount.add(_amount);
                uint256 _bonusAmount = _amount.mul(userBonus(_pid, _user).add(10000)).div(10000);
                user.amountWithBonus = user.amountWithBonus.add(_bonusAmount);
                pool.lpSupply = pool.lpSupply.add(_bonusAmount);
            }
        }
        user.rewardDebt = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }

    // Withdraw LP tokens from MasterUranium.
    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            if(pool.isSRadsRewards){
                safeSRadsTransfer(msg.sender, pending);
            }
            else{
                safeRadsTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            uint256 _bonusAmount = _amount.mul(userBonus(_pid, msg.sender).add(10000)).div(10000);
            user.amountWithBonus = user.amountWithBonus.sub(_bonusAmount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            pool.lpSupply = pool.lpSupply.sub(_bonusAmount);
        }
        user.rewardDebt = user.amountWithBonus.mul(pool.accRadsPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        pool.lpSupply = pool.lpSupply.sub(user.amountWithBonus);
        user.amount = 0;
        user.rewardDebt = 0;
        user.amountWithBonus = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function getPoolInfo(uint256 _pid) external view
    returns(address lpToken, uint256 allocPoint, uint256 lastRewardBlock,
            uint256 accRadsPerShare, uint256 depositFeeBP, bool isSRadsRewards) {
        return (
            address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].accRadsPerShare,
            poolInfo[_pid].depositFeeBP,
            poolInfo[_pid].isSRadsRewards
        );
    }

    // Safe rads transfer function, just in case if rounding error causes pool to not have enough RADSs.
    function safeRadsTransfer(address _to, uint256 _amount) internal {
        uint256 radsBal = rads.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > radsBal) {
            transferSuccess = rads.transfer(_to, radsBal);
        } else {
            transferSuccess = rads.transfer(_to, _amount);
        }
        require(transferSuccess, "safeRadsTransfer: Transfer failed");
    }

    // Safe sRads transfer function, just in case if rounding error causes pool to not have enough SRADSs.
    function safeSRadsTransfer(address _to, uint256 _amount) internal {
        uint256 sRadsBal = sRads.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > sRadsBal) {
            transferSuccess = sRads.transfer(_to, sRadsBal);
        } else {
            transferSuccess = sRads.transfer(_to, _amount);
        }
        require(transferSuccess, "safeSRadsTransfer: Transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) external {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        feeAddress = _feeAddress;
    }

    function updateMinimumEmissionRate(uint256 _minimumEmissionRate) external onlyOwner{
        require(minimumEmissionRate > _minimumEmissionRate, "must be lower");
        minimumEmissionRate = _minimumEmissionRate;
        if(radsPerBlock == minimumEmissionRate){
            lastReductionPeriodIndex = block.number.sub(startBlock).div(emissionReductionPeriodBlocks);
        }
    }

}
