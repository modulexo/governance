// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/*──────────────────────────────────────────
│ Merkle Utilities
──────────────────────────────────────────*/
library MerkleLib {
    function verify(bytes32 root, bytes32 leafHash, bytes32[] memory proof)
        internal
        pure
        returns (bool ok)
    {
        bytes32 h = leafHash;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            h = (h < p)
                ? keccak256(abi.encodePacked(h, p))
                : keccak256(abi.encodePacked(p, h));
        }
        return h == root;
    }

    function leaf(address voter, uint256 weight) internal pure returns (bytes32) {
        return keccak256(abi.encode(voter, weight));
    }
}

interface IFund3Votes {
    function shareBalances(address user) external view returns (uint256);
    function totalShares() external view returns (uint256);
}

/**
 * WeightedFundGovernor (Merkle-snapshot voting)
 *
 * - Propose threshold: live Fund shareBalances(msg.sender)
 * - Voting weights: provided by Merkle snapshot root (set by Timelock)
 *
 * Hardening:
 * - Votes require snapshot root set
 * - Strict support enum: 0=Against, 1=For, 2=Abstain
 * - Param setters: bounded + events
 * - Proposal action count cap to prevent grief
 */
contract WeightedFundGovernor {
    using MerkleLib for bytes32;

    /*────────── Errors ──────────*/
    error NotTimelock();
    error BadArrays();
    error Exists();
    error BelowThreshold();
    error Closed();
    error SnapshotMissing();
    error SnapshotAlready();
    error BadSupport();
    error AlreadyVoted();
    error NotSucceeded();
    error BadState();
    error BadParam();

    /*────────── Events ──────────*/
    event ProposalCreated(bytes32 indexed id, uint64 voteStart, uint64 voteEnd, string description);
    event SnapshotRootSet(bytes32 indexed id, bytes32 root);
    event VoteCast(bytes32 indexed id, address indexed voter, uint8 support, uint256 weight);
    event ProposalQueued(bytes32 indexed id, bytes32 timelockSalt);
    event ProposalExecuted(bytes32 indexed id);

    event VotingPeriodUpdated(uint256 v);
    event QuorumUpdated(uint256 v);
    event ProposeThresholdUpdated(uint256 v);
    event ActionCapUpdated(uint256 v);

    /*────────── Storage ──────────*/
    struct Proposal {
        uint64 voteStart;
        uint64 voteEnd;

        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;

        bool snapshotSet;
        bool queued;
        bool executed;

        bytes32 snapshotRoot;
        mapping(address => bool) hasVoted;

        address[] targets;
        uint256[] values;
        bytes[] calldatas;

        bytes32 descriptionHash;
        bytes32 timelockSalt;
    }

    TimelockController public immutable timelock;
    IFund3Votes public immutable fund;

    // governance params
    uint256 public votingPeriod;        // seconds
    uint256 public quorum;              // weight units (must match snapshot weights)
    uint256 public proposeThreshold;    // shares (Fund units)
    uint256 public maxActions;          // proposal actions cap

    mapping(bytes32 => Proposal) private _proposals;

    constructor(
        address timelockAddr,
        address fundAddr,
        uint256 votingPeriodSeconds,
        uint256 quorumWeight,
        uint256 thresholdShares
    ) {
        require(timelockAddr != address(0) && fundAddr != address(0), "zero");
        timelock = TimelockController(payable(timelockAddr));
        fund = IFund3Votes(fundAddr);

        votingPeriod = votingPeriodSeconds;
        quorum = quorumWeight;
        proposeThreshold = thresholdShares;
        maxActions = 32;
    }

    modifier onlyTimelock() {
        if (msg.sender != address(timelock)) revert NotTimelock();
        _;
    }

    /*────────── Timelock-controlled params ──────────*/
    function setVotingPeriod(uint256 v) external onlyTimelock {
        if (v < 1 hours || v > 30 days) revert BadParam();
        votingPeriod = v;
        emit VotingPeriodUpdated(v);
    }

    function setQuorum(uint256 v) external onlyTimelock {
        // allow 0 (turn off quorum) if you want, but generally set >0
        quorum = v;
        emit QuorumUpdated(v);
    }

    function setProposeThreshold(uint256 v) external onlyTimelock {
        proposeThreshold = v;
        emit ProposeThresholdUpdated(v);
    }

    function setMaxActions(uint256 v) external onlyTimelock {
        if (v == 0 || v > 128) revert BadParam();
        maxActions = v;
        emit ActionCapUpdated(v);
    }

    /*────────── Proposal Lifecycle ──────────*/
    function hashProposal(
        address[] memory t,
        uint256[] memory v,
        bytes[] memory c,
        bytes32 dHash
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(t, v, c, dHash));
    }

    function propose(
        address[] memory t,
        uint256[] memory v,
        bytes[] memory c,
        string memory description
    ) external returns (bytes32 id) {
        if (t.length == 0 || t.length != v.length || t.length != c.length) revert BadArrays();
        if (t.length > maxActions) revert BadParam();
        if (fund.shareBalances(msg.sender) < proposeThreshold) revert BelowThreshold();

        bytes32 dHash = keccak256(bytes(description));
        id = hashProposal(t, v, c, dHash);

        Proposal storage p = _proposals[id];
        if (p.voteEnd != 0) revert Exists();

        p.voteStart = uint64(block.timestamp);
        p.voteEnd   = uint64(block.timestamp + votingPeriod);

        p.targets = t;
        p.values = v;
        p.calldatas = c;
        p.descriptionHash = dHash;

        emit ProposalCreated(id, p.voteStart, p.voteEnd, description);
    }

    function setSnapshotRoot(bytes32 id, bytes32 root) external onlyTimelock {
        Proposal storage p = _proposals[id];
        if (p.voteStart == 0 || block.timestamp >= p.voteEnd) revert Closed();
        if (p.snapshotSet) revert SnapshotAlready();
        p.snapshotRoot = root;
        p.snapshotSet = true;
        emit SnapshotRootSet(id, root);
    }

    // support: 0=Against, 1=For, 2=Abstain
    function castVote(bytes32 id, uint8 support, uint256 weight, bytes32[] calldata proof) external {
        Proposal storage p = _proposals[id];
        if (p.voteEnd == 0) revert BadState();
        if (block.timestamp >= p.voteEnd) revert Closed();
        if (!p.snapshotSet) revert SnapshotMissing();
        if (support > 2) revert BadSupport();
        if (p.hasVoted[msg.sender]) revert AlreadyVoted();

        bytes32 leafHash = MerkleLib.leaf(msg.sender, weight);
        require(MerkleLib.verify(p.snapshotRoot, leafHash, proof), "bad proof");

        p.hasVoted[msg.sender] = true;

        if (support == 0) p.againstVotes += weight;
        else if (support == 1) p.forVotes += weight;
        else p.abstainVotes += weight;

        emit VoteCast(id, msg.sender, support, weight);
    }

    /**
     * state:
     * 0 None, 1 Active, 2 Defeated, 3 Succeeded, 4 Queued, 5 Executed
     */
    function state(bytes32 id) public view returns (uint8) {
        Proposal storage p = _proposals[id];
        if (p.voteEnd == 0) return 0;
        if (block.timestamp < p.voteEnd) return 1;
        if (p.executed) return 5;
        if (p.queued) return 4;

        // ended; must have snapshot set
        if (!p.snapshotSet) return 2;

        // quorum check
        uint256 totalVotes = p.forVotes + p.againstVotes + p.abstainVotes;
        if (quorum > 0 && totalVotes < quorum) return 2;

        // majority
        if (p.forVotes <= p.againstVotes) return 2;
        return 3;
    }

    function queue(bytes32 id) external {
        if (state(id) != 3) revert NotSucceeded();

        Proposal storage p = _proposals[id];
        require(!p.queued && !p.executed, "bad");

        // deterministic salt prevents collisions across proposals
        bytes32 salt = keccak256(abi.encode(id, p.descriptionHash, address(this)));
        p.timelockSalt = salt;

        timelock.scheduleBatch(
            p.targets,
            p.values,
            p.calldatas,
            bytes32(0),
            salt,
            timelock.getMinDelay()
        );

        p.queued = true;
        emit ProposalQueued(id, salt);
    }

    function execute(bytes32 id) external payable {
        Proposal storage p = _proposals[id];
        require(p.queued && !p.executed, "bad");

        timelock.executeBatch{value: msg.value}(
            p.targets,
            p.values,
            p.calldatas,
            bytes32(0),
            p.timelockSalt
        );

        p.executed = true;
        emit ProposalExecuted(id);
    }

    /*────────── Read helpers ──────────*/
    function getProposalMeta(bytes32 id)
        external
        view
        returns (
            uint64 voteStart,
            uint64 voteEnd,
            bool snapshotSet,
            bool queued,
            bool executed,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bytes32 snapshotRoot
        )
    {
        Proposal storage p = _proposals[id];
        return (
            p.voteStart,
            p.voteEnd,
            p.snapshotSet,
            p.queued,
            p.executed,
            p.forVotes,
            p.againstVotes,
            p.abstainVotes,
            p.snapshotRoot
        );
    }
}
