pragma solidity 0.5.11;

import "./SafeMath.sol";

contract StakersConstants {
    uint256 internal constant OK_STATUS = 0;
    uint256 internal constant FORK_BIT = 1;
    uint256 internal constant OFFLINE_BIT = 1 << 8;
    uint256 internal constant CHEATER_MASK = FORK_BIT;
    uint256 internal constant PERCENT_UNIT = 1000000;

    function minStake() public pure returns (uint256) {
        return 3175000 * 1e18; // 3175000 FTM
    }

    function minStakeIncrease() public pure returns (uint256) {
        return 1 * 1e18;
    }

    function minDelegation() public pure returns (uint256) {
        return 1 * 1e18;
    }

    function maxDelegatedRatio() public pure returns (uint256) {
        return 15 * PERCENT_UNIT; // 1500%
    }

    function validatorCommission() public pure returns (uint256) {
        return (15 * PERCENT_UNIT) / 100; // 15%
    }

    function contractCommission() public pure returns (uint256) {
        return (30 * PERCENT_UNIT) / 100; // 30%
    }

    function stakeLockPeriodTime() public pure returns (uint256) {
        return 60 * 60 * 24 * 7; // 7 days
    }

    function stakeLockPeriodEpochs() public pure returns (uint256) {
        return 3;
    }

    function delegationLockPeriodTime() public pure returns (uint256) {
        return 60 * 60 * 24 * 7; // 7 days
    }

    function delegationLockPeriodEpochs() public pure returns (uint256) {
        return 3;
    }

    event UpdatedBaseRewardPerSec(uint256 value);
    event UpdatedGasPowerAllocationRate(uint256 short, uint256 long);
}

contract Stakers is StakersConstants {
    using SafeMath for uint256;

    struct Delegation {
        uint256 createdEpoch;
        uint256 createdTime;

        uint256 deactivatedEpoch;
        uint256 deactivatedTime;

        uint256 amount;
        uint256 paidUntilEpoch;
        uint256 toStakerID;
    }

    struct ValidationStake {
        uint256 status; // written by consensus outside

        uint256 createdEpoch;
        uint256 createdTime;
        uint256 deactivatedEpoch;
        uint256 deactivatedTime;

        uint256 stakeAmount;
        uint256 paidUntilEpoch;

        uint256 delegatedMe;

        address stakerAddress;
    }

    struct ValidatorMerit {
        uint256 stakeAmount;
        uint256 delegatedMe;
        uint256 baseRewardWeight;
        uint256 txRewardWeight;
    }

    struct EpochSnapshot {
        mapping(uint256 => ValidatorMerit) validators; //  stakerID -> ValidatorMerit

        uint256 endTime;
        uint256 duration;
        uint256 epochFee;
        uint256 totalBaseRewardWeight;
        uint256 totalTxRewardWeight;
        uint256 baseRewardPerSecond;
    }

    uint256 public currentSealedEpoch; // written by consensus outside
    mapping(uint256 => EpochSnapshot) public epochSnapshots; // written by consensus outside
    mapping(uint256 => ValidationStake) public stakers; // stakerID -> stake
    mapping(address => uint256) internal stakerIDs; // staker address -> stakerID

    uint256 public stakersLastID;
    uint256 public stakersNum;
    uint256 public stakeTotalAmount;
    uint256 public delegationsNum;
    uint256 public delegationsTotalAmount;
    uint256 public slashedDelegationsTotalAmount;
    uint256 public slashedStakeTotalAmount;

    mapping(address => Delegation) public delegations; // delegationID -> delegation

    /*
    Getters
    */

    function epochValidator(uint256 e, uint256 v) external view returns (uint256 stakeAmount, uint256 delegatedMe, uint256 baseRewardWeight, uint256 txRewardWeight) {
        return (epochSnapshots[e].validators[v].stakeAmount,
                epochSnapshots[e].validators[v].delegatedMe,
                epochSnapshots[e].validators[v].baseRewardWeight,
                epochSnapshots[e].validators[v].txRewardWeight);
    }

    function currentEpoch() public view returns (uint256) {
        return currentSealedEpoch + 1;
    }

    function getStakerID(address addr) external view returns (uint256) {
        return stakerIDs[addr];
    }

    /*
    Methods
    */

    event CreatedStake(uint256 indexed stakerID, address indexed stakerAddress, uint256 amount);

    // Create new staker
    // Stake amount is msg.value
    function createStake() external payable {
        implCreateStake();
    }

    function implCreateStake() internal {
        address staker = msg.sender;

        require(stakerIDs[staker] == 0, "staker already exists");
        require(delegations[staker].amount == 0, "already delegating");
        require(msg.value >= minStake(), "insufficient amount");

        uint256 stakerID = ++stakersLastID;
        stakerIDs[staker] = stakerID;
        stakers[stakerID].stakeAmount = msg.value;
        stakers[stakerID].createdEpoch = currentEpoch();
        stakers[stakerID].createdTime = block.timestamp;
        stakers[stakerID].stakerAddress = staker;
        stakers[stakerID].paidUntilEpoch = currentSealedEpoch;

        stakersNum++;
        stakeTotalAmount = stakeTotalAmount.add(msg.value);
        emit CreatedStake(stakerID, staker, msg.value);
    }

    event IncreasedStake(uint256 indexed stakerID, uint256 newAmount, uint256 diff);

    // Increase msg.sender's stake by msg.value
    function increaseStake() external payable {
        address staker = msg.sender;
        uint256 stakerID = stakerIDs[staker];

        require(msg.value >= minStakeIncrease(), "insufficient amount");
        require(stakers[stakerID].stakeAmount != 0, "staker doesn't exist");
        require(stakers[stakerID].deactivatedTime == 0, "staker is deactivated");
        require(stakers[stakerID].status == OK_STATUS, "staker should be active");

        uint256 newAmount = stakers[stakerID].stakeAmount.add(msg.value);
        stakers[stakerID].stakeAmount = newAmount;
        stakeTotalAmount = stakeTotalAmount.add(msg.value);
        emit IncreasedStake(stakerID, newAmount, msg.value);
    }

    event CreatedDelegation(address indexed from, uint256 indexed toStakerID, uint256 amount);

    // Create new delegation to a given staker
    // Delegated amount is msg.value
    function createDelegation(uint256 to) external payable {
        address from = msg.sender;

        require(stakers[to].stakeAmount != 0, "staker doesn't exist");
        require(stakers[to].status == OK_STATUS, "staker should be active");
        require(msg.value >= minDelegation(), "insufficient amount for delegation");
        require(delegations[from].amount == 0, "delegation already exists");
        require(stakerIDs[from] == 0, "already staking");
        require((stakers[to].stakeAmount.mul(maxDelegatedRatio())).div(PERCENT_UNIT) >= stakers[to].delegatedMe.add(msg.value), "staker's limit is exceeded");

        Delegation memory newDelegation;
        newDelegation.createdEpoch = currentEpoch();
        newDelegation.createdTime = block.timestamp;
        newDelegation.amount = msg.value;
        newDelegation.toStakerID = to;
        newDelegation.paidUntilEpoch = currentSealedEpoch;
        delegations[from] = newDelegation;

        stakers[to].delegatedMe = stakers[to].delegatedMe.add(msg.value);
        delegationsNum++;
        delegationsTotalAmount = delegationsTotalAmount.add(msg.value);

        emit CreatedDelegation(from, to, msg.value);
    }

    function calcTotalReward(uint256 stakerID, uint256 epoch) view public returns (uint256) {
        uint256 totalBaseRewardWeight = epochSnapshots[epoch].totalBaseRewardWeight;
        uint256 baseRewardWeight = epochSnapshots[epoch].validators[stakerID].baseRewardWeight;
        uint256 totalTxRewardWeight = epochSnapshots[epoch].totalTxRewardWeight;
        uint256 txRewardWeight = epochSnapshots[epoch].validators[stakerID].txRewardWeight;

        // base reward
        uint256 baseReward = 0;
        if (baseRewardWeight != 0) {
            baseReward = epochSnapshots[epoch].duration.mul(epochSnapshots[epoch].baseRewardPerSecond).mul(baseRewardWeight).div(totalBaseRewardWeight);
        }
        // fee reward
        uint256 txReward = 0;
        if (txRewardWeight != 0) {
            txReward = epochSnapshots[epoch].epochFee.mul(txRewardWeight).div(totalTxRewardWeight);
            // fee reward except contractCommission
            txReward = txReward.mul(PERCENT_UNIT - contractCommission()).div(PERCENT_UNIT);
        }

        return baseReward.add(txReward);
    }

    function calcValidatorReward(uint256 stakerID, uint256 epoch) view public returns (uint256) {
        uint256 fullReward = calcTotalReward(stakerID, epoch);

        uint256 stake = epochSnapshots[epoch].validators[stakerID].stakeAmount;
        uint256 delegatedTotal = epochSnapshots[epoch].validators[stakerID].delegatedMe;
        uint256 totalStake = stake.add(delegatedTotal);
        if (totalStake == 0) {
            return 0; // avoid division by zero
        }
        uint256 weightedTotalStake = stake.add((delegatedTotal.mul(validatorCommission())).div(PERCENT_UNIT));
        return (fullReward.mul(weightedTotalStake)).div(totalStake);
    }

    function calcDelegationReward(uint256 stakerID, uint256 epoch, uint256 delegatedAmount) view public returns (uint256) {
        uint256 fullReward = calcTotalReward(stakerID, epoch);

        uint256 stake = epochSnapshots[epoch].validators[stakerID].stakeAmount;
        uint256 delegatedTotal = epochSnapshots[epoch].validators[stakerID].delegatedMe;
        uint256 totalStake = stake.add(delegatedTotal);
        if (totalStake == 0) {
            return 0; // avoid division by zero
        }
        uint256 weightedTotalStake = (delegatedAmount.mul(PERCENT_UNIT.sub(validatorCommission()))).div(PERCENT_UNIT);
        return (fullReward.mul(weightedTotalStake)).div(totalStake);
    }

    function withDefault(uint256 a, uint256 defaultA) pure private returns(uint256) {
        if (a == 0) {
            return defaultA;
        }
        return a;
    }

    // Returns the pending rewards for a given delegator, first calculated epoch, last calculated epoch
    // _fromEpoch is starting epoch which rewards are calculated (including). If 0, then it's lowest not claimed epoch
    // maxEpochs is maximum number of epoch to calc rewards for. Set it to your chunk size.
    function calcDelegationRewards(address delegator, uint256 _fromEpoch, uint256 maxEpochs) public view returns (uint256, uint256, uint256) {
        uint256 stakerID = delegations[delegator].toStakerID;
        uint256 fromEpoch = withDefault(_fromEpoch, delegations[delegator].paidUntilEpoch + 1);
        assert(delegations[delegator].deactivatedTime == 0);

        uint256 pendingRewards = 0;
        uint256 lastPaid = 0;
        for (uint256 e = fromEpoch; e <= currentSealedEpoch && e < fromEpoch + maxEpochs; e++) {
            pendingRewards += calcDelegationReward(stakerID, e, delegations[delegator].amount);
            lastPaid = e;
        }
        return (pendingRewards, fromEpoch, lastPaid);
    }

    // Returns the pending rewards for a given stakerID, first claimed epoch, last claimed epoch
    // _fromEpoch is starting epoch which rewards are calculated (including). If 0, then it's lowest not claimed epoch
    // maxEpochs is maximum number of epoch to calc rewards for. Set it to your chunk size.
    function calcValidatorRewards(uint256 stakerID, uint256 _fromEpoch, uint256 maxEpochs) public view returns (uint256, uint256, uint256) {
        uint256 fromEpoch = withDefault(_fromEpoch, stakers[stakerID].paidUntilEpoch + 1);

        uint256 pendingRewards = 0;
        uint256 lastPaid = 0;
        for (uint256 e = fromEpoch; e <= currentSealedEpoch && e < fromEpoch + maxEpochs; e++) {
            pendingRewards += calcValidatorReward(stakerID, e);
            lastPaid = e;
        }
        return (pendingRewards, fromEpoch, lastPaid);
    }

    event ClaimedDelegationReward(address indexed from, uint256 indexed stakerID, uint256 reward, uint256 fromEpoch, uint256 untilEpoch);

    // Claim the pending rewards for a given delegator (sender)
    // _fromEpoch is starting epoch which rewards are calculated (including). If 0, then it's lowest not claimed epoch
    // maxEpochs is maximum number of epoch to calc rewards for. Set it to your chunk size.
    function claimDelegationRewards(uint256 _fromEpoch, uint256 maxEpochs) external {
        address payable delegator = msg.sender;

        require(delegations[delegator].amount != 0, "delegation doesn't exist");
        require(delegations[delegator].deactivatedTime == 0, "delegation is deactivated");

        uint256 pendingRewards;
        uint256 fromEpoch;
        uint256 untilEpoch;
        (pendingRewards, fromEpoch, untilEpoch) = calcDelegationRewards(delegator, _fromEpoch, maxEpochs);

        require(delegations[delegator].paidUntilEpoch < fromEpoch, "epoch is already paid");
        require(fromEpoch <= currentSealedEpoch, "future epoch");
        require(untilEpoch >= fromEpoch, "no epochs claimed");

        delegations[delegator].paidUntilEpoch = untilEpoch;
        // It's important that we transfer after updating paidUntilEpoch (protection against Re-Entrancy)
        delegator.transfer(pendingRewards);

        uint256 stakerID = delegations[delegator].toStakerID;
        emit ClaimedDelegationReward(delegator, stakerID, pendingRewards, fromEpoch, untilEpoch);
    }

    event ClaimedValidatorReward(uint256 indexed stakerID, uint256 reward, uint256 fromEpoch, uint256 untilEpoch);

    // Claim the pending rewards for a given stakerID (sender)
    // _fromEpoch is starting epoch which rewards are calculated (including). If 0, then it's lowest not claimed epoch
    // maxEpochs is maximum number of epoch to calc rewards for. Set it to your chunk size.
    //
    // may be already deactivated, but still allowed to withdraw old rewards
    function claimValidatorRewards(uint256 _fromEpoch, uint256 maxEpochs) external {
        address payable staker = msg.sender;
        uint256 stakerID = stakerIDs[staker];

        require(stakerID != 0, "staker doesn't exist");

        uint256 pendingRewards;
        uint256 fromEpoch;
        uint256 untilEpoch;
        (pendingRewards, fromEpoch, untilEpoch) = calcValidatorRewards(stakerID, _fromEpoch, maxEpochs);

        require(stakers[stakerID].paidUntilEpoch < fromEpoch, "epoch is already paid");
        require(fromEpoch <= currentSealedEpoch, "future epoch");
        require(untilEpoch >= fromEpoch, "no epochs claimed");

        stakers[stakerID].paidUntilEpoch = untilEpoch;
        // It's important that we transfer after updating paidUntilEpoch (protection against Re-Entrancy)
        staker.transfer(pendingRewards);

        emit ClaimedValidatorReward(stakerID, pendingRewards, fromEpoch, untilEpoch);
    }

    event PreparedToWithdrawStake(uint256 indexed stakerID);

    // deactivate stake, to be able to withdraw later
    function prepareToWithdrawStake() external {
        address staker = msg.sender;
        uint256 stakerID = stakerIDs[staker];
        require(stakers[stakerID].stakeAmount != 0, "staker doesn't exist");
        require(stakers[stakerID].deactivatedTime == 0, "staker is deactivated");

        stakers[stakerID].deactivatedEpoch = currentEpoch();
        stakers[stakerID].deactivatedTime = block.timestamp;

        emit PreparedToWithdrawStake(stakerID);
    }

    event WithdrawnStake(uint256 indexed stakerID, uint256 penalty);

    function withdrawStake() external {
        address payable staker = msg.sender;
        uint256 stakerID = stakerIDs[staker];
        require(stakers[stakerID].deactivatedTime != 0, "staker wasn't deactivated");
        require(block.timestamp >= stakers[stakerID].deactivatedTime + stakeLockPeriodTime(), "not enough time passed");
        require(currentEpoch() >= stakers[stakerID].deactivatedEpoch + stakeLockPeriodEpochs(), "not enough epochs passed");

        uint256 stake = stakers[stakerID].stakeAmount;
        uint256 penalty = 0;
        bool isCheater = stakers[stakerID].status & CHEATER_MASK != 0;
        delete stakers[stakerID];
        delete stakerIDs[staker];

        stakersNum--;
        stakeTotalAmount = stakeTotalAmount.sub(stake);
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        if (isCheater == false) {
            staker.transfer(stake);
        } else {
            penalty = stake;
        }

        slashedStakeTotalAmount = slashedStakeTotalAmount.add(penalty);

        emit WithdrawnStake(stakerID, penalty);
    }

    event PreparedToWithdrawDelegation(address indexed from, uint256 indexed stakerID);

    // deactivate delegation, to be able to withdraw later
    function prepareToWithdrawDelegation() external {
        address from = msg.sender;
        require(delegations[from].amount != 0, "delegation doesn't exist");
        require(delegations[from].deactivatedTime == 0, "delegation is deactivated");

        delegations[from].deactivatedEpoch = currentEpoch();
        delegations[from].deactivatedTime = block.timestamp;
        uint256 stakerID = delegations[from].toStakerID;
        uint256 delegatedAmount = delegations[from].amount;
        if (stakers[stakerID].stakeAmount != 0) {
            // if staker haven't withdrawn
            stakers[stakerID].delegatedMe = stakers[stakerID].delegatedMe.sub(delegatedAmount);
        }

        emit PreparedToWithdrawDelegation(from, stakerID);
    }

    event WithdrawnDelegation(address indexed from, uint256 indexed stakerID, uint256 penalty);

    function withdrawDelegation() external {
        address payable from = msg.sender;
        require(delegations[from].deactivatedTime != 0, "delegation wasn't deactivated");
        require(block.timestamp >= delegations[from].deactivatedTime + delegationLockPeriodTime(), "not enough time passed");
        require(currentEpoch() >= delegations[from].deactivatedEpoch + delegationLockPeriodEpochs(), "not enough epochs passed");
        uint256 stakerID = delegations[from].toStakerID;
        uint256 penalty = 0;
        bool isCheater = stakers[stakerID].status & CHEATER_MASK != 0;
        uint256 delegatedAmount = delegations[from].amount;
        delete delegations[from];

        delegationsNum--;
        delegationsTotalAmount = delegationsTotalAmount.sub(delegatedAmount);
        // It's important that we transfer after erasing (protection against Re-Entrancy)
        if (isCheater == false) {
            from.transfer(delegatedAmount);
        } else {
            penalty = delegatedAmount;
        }

        slashedDelegationsTotalAmount = slashedDelegationsTotalAmount.add(penalty);

        emit WithdrawnDelegation(from, stakerID, penalty);
    }
}

contract TestStakers is Stakers {
    function stakeLockPeriodTime() public pure returns (uint256) {
        return 1 * 60;
    }

    function delegationLockPeriodTime() public pure returns (uint256) {
        return 1 * 60;
    }

    function _updateGasPowerAllocationRate(uint256 short, uint256 long) external {
        emit UpdatedGasPowerAllocationRate(short, long);
    }

    function _updateBaseRewardPerSec(uint256 value) external {
        emit UpdatedBaseRewardPerSec(value);
    }
}

contract UnitTestStakers is Stakers {
    uint256[] public stakerIDsArr;

    function _baseRewardPerSecond() public pure returns (uint256) {
        return 0.0000000001 * 1e18;
    }

    function minStake() public pure returns (uint256) {
        return 1 * 1e18;
    }

    function minStakeIncrease() public pure returns (uint256) {
        return 1 * 1e18;
    }

    function minDelegation() public pure returns (uint256) {
        return 1 * 1e18;
    }

    constructor (uint256 firstEpoch) public {
        currentSealedEpoch = firstEpoch;
    }

    function _markValidationStakeAsCheater(uint256 stakerID, bool cheater) external {
        if (stakers[stakerID].stakeAmount != 0) {
            if (cheater) {
                stakers[stakerID].status = FORK_BIT;
            } else {
                stakers[stakerID].status = 0;
            }
        }
    }

    function _createStake() external payable {
        stakerIDsArr.push(stakersLastID + 1); // SS Check existing?
        super.implCreateStake();
    }

    function _makeEpochSnapshots(uint256 optionalDuration) external returns(uint256) {
        currentSealedEpoch++;
        EpochSnapshot storage newSnapshot = epochSnapshots[currentSealedEpoch];
        uint256 epochPay = 0;

        newSnapshot.endTime = block.timestamp;
        if (optionalDuration != 0 || currentSealedEpoch == 0) {
            newSnapshot.duration = optionalDuration;
        } else {
            newSnapshot.duration = block.timestamp - epochSnapshots[currentSealedEpoch - 1].endTime;
        }
        epochPay += newSnapshot.duration * _baseRewardPerSecond();

        for (uint256 i = 0; i < stakerIDsArr.length; i++) {
            uint256 deactivatedTime = stakers[stakerIDsArr[i]].deactivatedTime;
            if (deactivatedTime == 0 || block.timestamp < deactivatedTime) {
                uint256 basePower = stakers[stakerIDsArr[i]].stakeAmount + stakers[stakerIDsArr[i]].delegatedMe;
                uint256 txPower = 1000 * i + basePower;
                newSnapshot.totalBaseRewardWeight += basePower;
                newSnapshot.totalTxRewardWeight += txPower;
                newSnapshot.baseRewardPerSecond = _baseRewardPerSecond();
                newSnapshot.validators[stakerIDsArr[i]] = ValidatorMerit(
                    stakers[stakerIDsArr[i]].stakeAmount,
                    stakers[stakerIDsArr[i]].delegatedMe,
                    basePower,
                    txPower
                );
            }
        }

        newSnapshot.epochFee = 2 * 1e18;
        epochPay += newSnapshot.epochFee;

        return epochPay;
    }
}
