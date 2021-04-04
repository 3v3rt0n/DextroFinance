pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";

import "./MasterUranium.sol";

contract UraniumBonusAggregator is Ownable{
    using SafeMath for uint256;
    using SafeMath for uint16;

    MasterUranium master;

    mapping(address => mapping(uint256 => uint16)) public userBonusOnFarms;

    mapping (address => bool) public contractBonusSource;

    /**
     * @dev Throws if called by any account other than the verified contracts.
     */
    modifier onlyVerifiedContract() {
        require(contractBonusSource[msg.sender], "caller is not in contract list");
        _;
    }

    function setupMaster(MasterUranium _master) external onlyOwner{
        master = _master;
    }

    function addOrRemoveContractBonusSource(address _contract, bool _add) external onlyOwner{
        contractBonusSource[_contract] = _add;
    }

    function addUserBonusOnFarm(address _user, uint16 _percent, uint256 _pid) external onlyVerifiedContract{
        require(_percent < 10000, "Invalid percent");
        userBonusOnFarms[_user][_pid] = uint16(userBonusOnFarms[_user][_pid].add(_percent));
        master.updateUserBonus(_user, _pid, userBonusOnFarms[_user][_pid]);
    }

    function removeUserBonusOnFarm(address _user, uint16 _percent, uint256 _pid) external onlyVerifiedContract{
        require(_percent < 10000, "Invalid percent");
        userBonusOnFarms[_user][_pid] = uint16(userBonusOnFarms[_user][_pid].sub(_percent));
        master.updateUserBonus(_user, _pid, userBonusOnFarms[_user][_pid]);
    }

    function getBonusOnFarmsForUser(address _user, uint256 _pid) public view returns (uint16){
        return userBonusOnFarms[_user][_pid];
    }

}
