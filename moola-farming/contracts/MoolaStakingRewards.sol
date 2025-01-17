// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time

pragma solidity ^0.8.3;

import "./ubeswap-farming/openzeppelin-solidity/contracts/Math.sol";
import "./ubeswap-farming/openzeppelin-solidity/contracts/SafeMath.sol";
import "./ubeswap-farming/openzeppelin-solidity/contracts/SafeERC20.sol";
import "./ubeswap-farming/openzeppelin-solidity/contracts/ReentrancyGuard.sol";

// Inheritance
import "./ubeswap-farming/synthetix/contracts/interfaces/IStakingRewards.sol";
import "./IMoolaStakingRewards.sol";
import "./ubeswap-farming/synthetix/contracts/RewardsDistributionRecipient.sol";

contract MoolaStakingRewards is IMoolaStakingRewards, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable rewardsToken;
    IERC20 public immutable stakingToken;
    IERC20[] public externalRewardsTokens;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public rewardsDuration = 7 days;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => mapping(IERC20 => uint256)) public externalRewards;

    mapping(IERC20 => uint256) private externalRewardPerTokenStoredWad;
    mapping(address => mapping(IERC20 => uint256)) private externalUserRewardPerTokenPaidWad;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    IStakingRewards public immutable externalStakingRewards;

    /* ========== EVENTS ========== */
    event PeriodFinishUpdated(uint256 originalFinish, uint256 newFinish);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsDistribution,
        IERC20 _rewardsToken,
        IStakingRewards _externalStakingRewards,
        IERC20[] memory _externalRewardsTokens
    ) Owned(_owner) {
        require(_externalRewardsTokens.length > 0, "Empty externalRewardsTokens");
        rewardsToken = _rewardsToken;
        rewardsDistribution = _rewardsDistribution;
        externalStakingRewards = _externalStakingRewards;
        externalRewardsTokens = _externalRewardsTokens;
        stakingToken = _externalStakingRewards.stakingToken();
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view override returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view override returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function earnedExternal(address account) public override returns (uint256[] memory result) {
        IERC20[] memory externalTokens = externalRewardsTokens;
        uint256[] memory externalOldTotalRewards = new uint256[](externalTokens.length);
        result = new uint256[](externalTokens.length);

        for (uint256 i = 0; i < externalTokens.length; i++) {
            externalOldTotalRewards[i] = externalTokens[i].balanceOf(address(this));
        }

        externalStakingRewards.getReward();

        for (uint256 i = 0; i < externalTokens.length; i++) {
            IERC20 externalToken = externalTokens[i];
            uint256 externalTotalRewards = externalToken.balanceOf(address(this));

            uint256 newExternalRewardsAmount = externalTotalRewards.sub(externalOldTotalRewards[i]);
            
            if (_totalSupply > 0) {
                externalRewardPerTokenStoredWad[externalToken] =
                    externalRewardPerTokenStoredWad[externalToken].add(newExternalRewardsAmount.mul(1e18).div(_totalSupply));
            }

            result[i] =
                _balances[account]
                .mul(externalRewardPerTokenStoredWad[externalToken].sub(externalUserRewardPerTokenPaidWad[account][externalToken]))
                .div(1e18).add(externalRewards[account][externalToken]);

            externalUserRewardPerTokenPaidWad[account][externalToken] = externalRewardPerTokenStoredWad[externalToken];
            externalRewards[account][externalToken] = result[i];
        }

        return result;
    }

    function getRewardForDuration() external view override returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // XXX: removed notPaused
    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        stakingToken.approve(address(externalStakingRewards), amount);
        externalStakingRewards.stake(amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        externalStakingRewards.withdraw(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        IERC20[] memory externalTokens = externalRewardsTokens;

        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }

        for (uint256 i = 0; i < externalTokens.length; i++) {
            IERC20 externalToken = externalTokens[i];
            uint256 externalReward = externalRewards[msg.sender][externalToken];
            if (externalReward > 0) {
                externalRewards[msg.sender][externalToken] = 0;
                externalToken.safeTransfer(msg.sender, externalReward);
                emit ExternalRewardPaid(msg.sender, externalReward);
            }
        }
    }

    function exit() external override {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint timestamp) external onlyOwner updateReward(address(0)) {
        uint256 oldPeriodFinish = periodFinish;
        periodFinish = timestamp;
        emit PeriodFinishUpdated(oldPeriodFinish, periodFinish);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
            earnedExternal(account);
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event ExternalRewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
