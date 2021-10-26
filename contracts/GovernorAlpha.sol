// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "./impl/GovernorAlphaStorage.sol";
import "./intf/ILpTokenWrapper.sol";
import "./intf/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract GovernorAlpha is GovernorAlphaStorage {
    using SafeMath for uint256;

    constructor() public {}

    function initialize() public onlyOnce {
        owner = msg.sender;
        admin = msg.sender;
        initialized = 1;
        proposalCount = 0;
        parameterMap[DeadlineDelayIndex] = 1 weeks;
        parameterMap[OneVotePerDFTIndex] = 1;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setAdmin(address newAdmin) public onlyOwner {
        require(newAdmin != address(0), "new admin is the zero");
        emit AdminSet(admin, newAdmin);
        admin = newAdmin;
    }

    function setAddress(uint256 index, address v) public onlyAdmin {
        addressMap[index] = v;
    }

    function setParameter(uint256 index, uint256 v) public onlyAdmin {
        parameterMap[index] = v;
    }

    function changeProposeEndTimestamp(uint256 proposalId, uint256 endTimestamp) public onlyAdmin {
        proposals[proposalId].endTimestamp = endTimestamp;
    }

    function joinGovernor() public {
        members[msg.sender].joined = true;
        emit GovernorJoin(msg.sender);
    }

    function exitGovernor() public {
        (bool res, ,) = canExitGovernor(msg.sender);
        require(res == true, "can not exit");
        members[msg.sender].joined = false;
        emit GovernorExit(msg.sender);
    }

    function isInGovernor(address v) public view returns(bool) {
        return members[v].joined;
    }

    function canExitGovernor(address voter) public view returns(bool res, uint8 reason, uint256 detail) {
        MemberInfo memory memberInfo = members[voter];
        if (members[voter].joined == false) {
            return (false, InvalidReasonNotInGovernor, 0);
        } else if (block.timestamp < memberInfo.lockedDeadline) {
            return (false, InvalidReasonNotReachDeadline, memberInfo.lockedDeadline);
        }
        return (true, InvalidReasonSucceed, 0);
    }

    function propose(ProposalInfo memory info) public onlyAdmin returns(uint256) {
        proposalCount++;

        Proposal memory newProposal = Proposal({
            id: proposalCount,
            proposer: msg.sender,
            description: info.description,
            startTimestamp: info.startTimestamp,
            endTimestamp: info.endTimestamp,
            forVotes: 0,
            againstVotes: 0,
            voterCount: 0,
            canceled: false,
            executed: false
        });

        proposals[newProposal.id] = newProposal;

        emit ProposalCreated(newProposal.id, msg.sender, info.description);

        return newProposal.id;
    }

    function cancel(uint256 proposalId) public onlyAdmin {
        require(proposalId > 0 && proposalId <= proposalCount, "invalid proposalId");
        proposals[proposalId].canceled = true;
        emit ProposalCanceled(proposalId);
    }

    function vote(uint256 proposalId, bool support, uint256 votes) public {
        voteInternal(msg.sender, proposalId, support, votes);
    }

    function voteInternal(address voter, uint256 proposalId, bool support, uint256 votes) internal {
        require(isInGovernor(voter) == true, "join governor first");
        require(state(proposalId) == ProposalState.Active, "proposal not active");
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        if (receipt.forVotes == 0 && receipt.againstVotes == 0) {
            proposal.voterCount++;
        }
        require(receipt.forVotes.add(receipt.againstVotes).add(votes) <= getVotes(voter), "exceed votes");
        if (support) {
            receipt.forVotes = receipt.forVotes.add(votes);
            proposal.forVotes = proposal.forVotes.add(votes);
        } else {
            receipt.againstVotes = receipt.againstVotes.add(votes);
            proposal.againstVotes = proposal.againstVotes.add(votes);
        }
        if (proposal.endTimestamp + parameterMap[DeadlineDelayIndex] > members[voter].lockedDeadline) {
            members[voter].lockedDeadline = proposal.endTimestamp + parameterMap[DeadlineDelayIndex];
        }
        emit VoteCast(voter, proposalId, support, votes);
    }

    function state(uint256 proposalId) public view returns(ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "invalid proposalId");
        Proposal memory proposal = proposals[proposalId];
        if (proposal.canceled == true) {
            return ProposalState.Canceled;
        } else if (block.timestamp < proposal.startTimestamp) {
            return ProposalState.Pending;
        } else if (block.timestamp < proposal.endTimestamp) {
            return ProposalState.Active;
        } else if (proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        } else {
            return ProposalState.Succeed;
        }
    }

    function getVotes(address voter) public view returns(uint256) {
        return getDftAmount(voter).div(parameterMap[OneVotePerDFTIndex]);
    }

    function getDftAmount(address voter) internal view returns(uint256) {
        ILpTokenWrapper wrapper = ILpTokenWrapper(address(addressMap[LpTokenWrapperIndex]));
        (uint256 stakedAmount, ,) = wrapper.getStakedDTokenInfo(voter);
        (uint256 acceleratedAmount, , ,) = wrapper.getAccelerateInfo(voter);
        (uint256 uniAmount,) = wrapper.getStakedUniInfo(voter, 9);
        uint256 uniDftAmount = 0;
        if (addressMap[UniswapV2PairAddressIndex] != address(0)) {
            IUniswapV2Pair pair = IUniswapV2Pair(addressMap[UniswapV2PairAddressIndex]);
            (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
            if (addressMap[DftAddressIndex] == pair.token0()) {
                uniDftAmount = uniAmount.mul(reserve0);
            } else {
                uniDftAmount = uniAmount.mul(reserve1);
            }
            uniDftAmount = uniDftAmount.div(pair.totalSupply());
        }
        return stakedAmount.add(acceleratedAmount).add(uniDftAmount);
    }

    function aggregateProposalInfo(uint256 proposalId)
        public
        view
        returns (
            uint256 voterCount,
            uint256 forVotes,
            uint256 againstVotes
        )
    {
        Proposal memory proposal = proposals[proposalId];
        voterCount = proposal.voterCount;
        forVotes = proposal.forVotes;
        againstVotes = proposal.againstVotes;
    }

    function aggregateProposalVoterInfo(address voter, uint256 proposalId)
        public
        view
        returns (
            uint256 votes,
            uint256 forVotes,
            uint256 againstVotes
        )
    {
        votes = getVotes(voter);
        forVotes = getVoted(voter, proposalId, true);
        againstVotes = getVoted(voter, proposalId, false);
    }

    function getVoted(address voter, uint256 proposalId, bool support) internal view returns(uint256) {
        if (support) {
            return proposals[proposalId].receipts[voter].forVotes;
        } else {
            return proposals[proposalId].receipts[voter].againstVotes;
        }
    }
}
