// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PredictionMarketplace
 * @dev A decentralized prediction marketplace where users can create markets, place bets,
 * and resolve markets through a staking-based resolver network.
 */
contract PredictionMarketplace is Ownable, ReentrancyGuard {
    // Fixed share price in ETH (0.0001 ETH = 10^14 wei)
    uint256 public sharePrice = 1 * 10**14;
    
    // Required stake amount to become a resolver (0.01 ETH)
    uint256 public constant RESOLVER_STAKE_AMOUNT = 1 * 10**16;
    
    // Platform fee percentage (0.5% = 50 basis points)
    uint256 public platformFeePercent = 50;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Market status enum
    enum MarketStatus { Active, Closed, Resolved }
    
    // Bet direction enum
    enum BetDirection { Yes, No }
    
    // Resolver vote enum
    enum ResolverVote { None, Yes, No, Invalid }
    
    // Resolver struct
    struct Resolver {
        uint256 stakedAmount;
        uint256 stakingTime;
        bool isActive;
    }
    
    // Market struct
    struct Market {
        address creator;
        string metadata;          // JSON string with market details
        uint256 startTime;
        uint256 endTime;
        uint256 totalYesShares;   // Total number of YES shares
        uint256 totalNoShares;    // Total number of NO shares
        uint256 creatorFee;       // in basis points (e.g., 100 = 1%)
        MarketStatus status;
        ResolverVote finalResult;
        uint256 yesVotes;
        uint256 noVotes;
        uint256 invalidVotes;
        mapping(address => uint256) yesShares; // Number of YES shares per user
        mapping(address => uint256) noShares;  // Number of NO shares per user
        mapping(address => bool) hasVoted;
        mapping(address => ResolverVote) resolverVotes;
    }
    
    // Platform address to collect fees
    address public platformAddress;
    
    // Mapping of market ID to Market
    mapping(uint256 => Market) public markets;
    
    // Mapping of resolver address to Resolver struct
    mapping(address => Resolver) public resolvers;
    
    // Array of all market IDs
    uint256[] public marketIds;
    
    // Array to track all resolver addresses
    address[] private resolverAddressArray;
    mapping(address => bool) private isKnownResolver;
    
    // Total markets counter
    uint256 public totalMarkets;
    
    // Events
    event MarketCreated(uint256 indexed marketId, address indexed creator, string metadata, uint256 startTime, uint256 endTime);
    event SharesBought(uint256 indexed marketId, address indexed bettor, BetDirection direction, uint256 shares, uint256 amount);
    event ResolverStaked(address indexed resolver, uint256 amount);
    event ResolverUnstaked(address indexed resolver, uint256 amount);
    event ResolverVoted(uint256 indexed marketId, address indexed resolver, ResolverVote vote);
    event MarketResolved(uint256 indexed marketId, ResolverVote result);
    event WinningsClaimed(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event SharePriceUpdated(uint256 oldSharePrice, uint256 newSharePrice);
    
    /**
     * @dev Constructor initializes the contract with the platform address
     * @param _platformAddress Address that will receive platform fees
     */
    constructor(address _platformAddress) Ownable(msg.sender) {
        require(_platformAddress != address(0), "Invalid platform address");
        platformAddress = _platformAddress;
    }
    
    /**
     * @dev Creates a new prediction market
     * @param _metadata JSON string with market details
     * @param _startTime Start time of the market
     * @param _endTime End time of the market
     * @param _creatorFee Creator fee in basis points (e.g., 100 = 1%)
     * @return marketId ID of the newly created market
     */
    function createMarket(
        string calldata _metadata,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _creatorFee
    ) external returns (uint256 marketId) {
        require(_startTime > block.timestamp, "Start time must be in the future");
        require(_endTime > _startTime, "End time must be after start time");
        require(_creatorFee <= 500, "Creator fee cannot exceed 5%");
        
        marketId = totalMarkets;
        
        Market storage newMarket = markets[marketId];
        newMarket.creator = msg.sender;
        newMarket.metadata = _metadata;
        newMarket.startTime = _startTime;
        newMarket.endTime = _endTime;
        newMarket.creatorFee = _creatorFee;
        newMarket.status = MarketStatus.Active;
        newMarket.finalResult = ResolverVote.None;
        
        marketIds.push(marketId);
        totalMarkets++;
        
        emit MarketCreated(marketId, msg.sender, _metadata, _startTime, _endTime);
        
        return marketId;
    }
    
    /**
     * @dev Buys shares in a market prediction
     * @param _marketId ID of the market
     * @param _direction Direction of the bet (Yes or No)
     * @param _shares Number of shares to buy
     */
    function buyShares(
        uint256 _marketId,
        BetDirection _direction,
        uint256 _shares
    ) external payable nonReentrant {
        Market storage market = markets[_marketId];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Active, "Market is not active");
        require(block.timestamp >= market.startTime, "Market has not started yet");
        require(block.timestamp < market.endTime, "Market has ended");
        require(_shares > 0, "Must buy at least one share");
        
        // Calculate required ETH amount
        uint256 requiredAmount = _shares * sharePrice;
        
        // Ensure correct ETH amount was sent
        require(msg.value == requiredAmount, "Incorrect ETH amount sent");
        
        // Update market stats
        if (_direction == BetDirection.Yes) {
            market.yesShares[msg.sender] += _shares;
            market.totalYesShares += _shares;
        } else {
            market.noShares[msg.sender] += _shares;
            market.totalNoShares += _shares;
        }
        
        emit SharesBought(_marketId, msg.sender, _direction, _shares, requiredAmount);
    }
    
    /**
     * @dev Closes a market when it reaches end time
     * @param _marketId ID of the market
     */
    function closeMarket(uint256 _marketId) external {
        Market storage market = markets[_marketId];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Active, "Market is not active");
        require(block.timestamp >= market.endTime, "Market has not ended yet");
        
        market.status = MarketStatus.Closed;
    }
    
    /**
     * @dev Stakes ETH to become a resolver
     */
    function stakeAsResolver() external payable nonReentrant {
        require(resolvers[msg.sender].isActive == false, "Already an active resolver");
        require(msg.value == RESOLVER_STAKE_AMOUNT, "Incorrect stake amount");
        
        // Update resolver info
        resolvers[msg.sender] = Resolver({
            stakedAmount: RESOLVER_STAKE_AMOUNT,
            stakingTime: block.timestamp,
            isActive: true
        });
        
        // Add to resolver address array if not already tracked
        if (!isKnownResolver[msg.sender]) {
            resolverAddressArray.push(msg.sender);
            isKnownResolver[msg.sender] = true;
        }
        
        emit ResolverStaked(msg.sender, RESOLVER_STAKE_AMOUNT);
    }
    
    /**
     * @dev Unstakes ETH and removes resolver status
     */
    function unstakeAsResolver() external nonReentrant {
        Resolver storage resolver = resolvers[msg.sender];
        
        require(resolver.isActive, "Not an active resolver");
        require(resolver.stakedAmount > 0, "No stake to withdraw");
        
        uint256 amountToReturn = resolver.stakedAmount;
        
        // Update resolver info
        resolver.stakedAmount = 0;
        resolver.isActive = false;
        
        // Transfer ETH back to resolver
        (bool success, ) = msg.sender.call{value: amountToReturn}("");
        require(success, "ETH transfer failed");
        
        emit ResolverUnstaked(msg.sender, amountToReturn);
    }
    
    /**
     * @dev Votes on a market's outcome (resolvers only)
     * @param _marketId ID of the market
     * @param _vote Vote (Yes, No, or Invalid)
     */
    function voteOnMarket(uint256 _marketId, ResolverVote _vote) external {
        require(_vote != ResolverVote.None, "Invalid vote option");
        
        Market storage market = markets[_marketId];
        Resolver storage resolver = resolvers[msg.sender];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Closed, "Market must be closed for voting");
        require(resolver.isActive, "Not an active resolver");
        require(resolver.stakingTime < market.startTime, "Must have staked before market started");
        require(!market.hasVoted[msg.sender], "Already voted on this market");
        
        // Record the vote
        market.hasVoted[msg.sender] = true;
        market.resolverVotes[msg.sender] = _vote;
        
        // Update vote counts
        if (_vote == ResolverVote.Yes) {
            market.yesVotes++;
        } else if (_vote == ResolverVote.No) {
            market.noVotes++;
        } else if (_vote == ResolverVote.Invalid) {
            market.invalidVotes++;
        }
        
        emit ResolverVoted(_marketId, msg.sender, _vote);
        
        // Check if we have a majority to finalize
        checkAndFinalizeMarket(_marketId);
    }
    
    /**
     * @dev Claims winnings from a resolved market
     * @param _marketId ID of the market
     */
    function claimWinnings(uint256 _marketId) external nonReentrant {
        Market storage market = markets[_marketId];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Resolved, "Market is not resolved");
        
        uint256 winningAmount = 0;
        
        if (market.finalResult == ResolverVote.Invalid) {
            // Return original bets if market is invalid
            uint256 yesSharesValue = market.yesShares[msg.sender] * sharePrice;
            uint256 noSharesValue = market.noShares[msg.sender] * sharePrice;
            winningAmount = yesSharesValue + noSharesValue;
            
            // Reset user's shares
            market.yesShares[msg.sender] = 0;
            market.noShares[msg.sender] = 0;
        } else {
            bool userHasWinningShares = false;
            uint256 userWinningShares = 0;
            uint256 totalWinningShares = 0;
            uint256 totalPoolValue = (market.totalYesShares + market.totalNoShares) * sharePrice;
            
            // Determine if user has winning shares and how many
            if (market.finalResult == ResolverVote.Yes && market.yesShares[msg.sender] > 0) {
                userHasWinningShares = true;
                userWinningShares = market.yesShares[msg.sender];
                totalWinningShares = market.totalYesShares;
                // Reset user's shares
                market.yesShares[msg.sender] = 0;
            } else if (market.finalResult == ResolverVote.No && market.noShares[msg.sender] > 0) {
                userHasWinningShares = true;
                userWinningShares = market.noShares[msg.sender];
                totalWinningShares = market.totalNoShares;
                // Reset user's shares
                market.noShares[msg.sender] = 0;
            }
            
            if (userHasWinningShares && totalWinningShares > 0) {
                // Pari-mutuel calculation: user's share of the total pot
                // winnings = (user shares / total winning shares) * total pool value
                winningAmount = (userWinningShares * totalPoolValue) / totalWinningShares;
                
                // Calculate fees
                uint256 platformFee = (winningAmount * platformFeePercent) / BASIS_POINTS;
                uint256 creatorFee = (winningAmount * market.creatorFee) / BASIS_POINTS;
                
                // Send fees
                if (platformFee > 0) {
                    (bool platformSuccess, ) = platformAddress.call{value: platformFee}("");
                    require(platformSuccess, "Platform fee transfer failed");
                }
                
                if (creatorFee > 0) {
                    (bool creatorSuccess, ) = market.creator.call{value: creatorFee}("");
                    require(creatorSuccess, "Creator fee transfer failed");
                }
                
                // Adjust winningAmount after fees
                winningAmount = winningAmount - platformFee - creatorFee;
            }
        }
        
        // Transfer winnings to user
        if (winningAmount > 0) {
            (bool success, ) = msg.sender.call{value: winningAmount}("");
            require(success, "Winnings transfer failed");
            emit WinningsClaimed(_marketId, msg.sender, winningAmount);
        }
    }
    
    /**
     * @dev Checks if a market can be finalized based on resolver votes
     * @param _marketId ID of the market
     */
    function checkAndFinalizeMarket(uint256 _marketId) internal {
        Market storage market = markets[_marketId];
        
        // Get total bets value in the market (shares * price)
        uint256 totalBetsValue = (market.totalYesShares + market.totalNoShares) * sharePrice;
        
        // Calculate total stake of voters who have voted
        uint256 totalVoterStake = getVoterStakeValue(_marketId);
        
        // Count total votes
        uint256 totalVotes = market.yesVotes + market.noVotes + market.invalidVotes;
        
        // DYNAMIC THRESHOLD BASED ON MARKET SIZE
        uint256 requiredVotes = 2; // Minimum of 2 votes for small markets
        
        // Medium markets (>= 0.1 ETH) need 3 votes
        if (totalBetsValue >= 0.1 ether) {
            requiredVotes = 3;
        }
        
        // Large markets (>= 0.5 ETH) need 5 votes
        if (totalBetsValue >= 0.5 ether) {
            requiredVotes = 5;
        }
        
        // Very large markets (>= 1 ETH) need 7 votes
        if (totalBetsValue >= 1 ether) {
            requiredVotes = 7;
        }
        
        // Check if we have enough votes
        if (totalVotes < requiredVotes) {
            return;
        }
        
        // Keep the economic security check
        if (totalVoterStake <= totalBetsValue) {
            return;
        }
        
        // Determine the outcome
        ResolverVote result;
        if (market.invalidVotes > market.yesVotes && market.invalidVotes > market.noVotes) {
            result = ResolverVote.Invalid;
        } else if (market.yesVotes > market.noVotes) {
            result = ResolverVote.Yes;
        } else {
            result = ResolverVote.No;
        }
        
        // Finalize the market
        market.status = MarketStatus.Resolved;
        market.finalResult = result;
        
        emit MarketResolved(_marketId, result);
    }
    /**
     * @dev Gets the number of resolvers eligible to vote on a market
     * @param _marketId ID of the market
     * @return count Number of eligible resolvers
     */
    function getEligibleResolversCount(uint256 _marketId) public view returns (uint256 count) {
        Market storage market = markets[_marketId];
        
        // Count active resolvers who staked before market started
        for (uint256 i = 0; i < resolverAddressArray.length; i++) {
            address resolverAddress = resolverAddressArray[i];
            Resolver storage resolver = resolvers[resolverAddress];
            
            if (resolver.isActive && resolver.stakingTime < market.startTime) {
                count++;
            }
        }
        
        return count;
    }
    
    /**
     * @dev Calculates the total ETH stake of resolvers who have voted on a market
     * @param _marketId ID of the market
     * @return totalStake Total ETH stake of voters
     */
    function getVoterStakeValue(uint256 _marketId) public view returns (uint256 totalStake) {
        Market storage market = markets[_marketId];
        
        for (uint256 i = 0; i < resolverAddressArray.length; i++) {
            address resolverAddress = resolverAddressArray[i];
            Resolver storage resolver = resolvers[resolverAddress];
            
            // Only count resolvers who have voted and were eligible to vote
            if (resolver.isActive && 
                resolver.stakingTime < market.startTime &&
                market.hasVoted[resolverAddress]) {
                totalStake += resolver.stakedAmount;
            }
        }
        
        return totalStake;
    }
    
    /**
     * @dev Gets user's shares for a market
     * @param _marketId ID of the market
     * @param _user Address of the user
     * @return yesShares Number of YES shares
     * @return noShares Number of NO shares
     */
    function getUserShares(uint256 _marketId, address _user) external view returns (uint256 yesShares, uint256 noShares) {
        Market storage market = markets[_marketId];
        
        return (market.yesShares[_user], market.noShares[_user]);
    }
    
    /**
     * @dev Sets the share price
     * @param _sharePrice New share price in wei
     */
    function setSharePrice(uint256 _sharePrice) external onlyOwner {
        require(_sharePrice > 0, "Share price must be greater than 0");
        uint256 oldSharePrice = sharePrice;
        sharePrice = _sharePrice;
        emit SharePriceUpdated(oldSharePrice, _sharePrice);
    }
    
    /**
     * @dev Sets the platform fee percentage
     * @param _platformFeePercent New platform fee percentage in basis points
     */
    function setPlatformFeePercent(uint256 _platformFeePercent) external onlyOwner {
        require(_platformFeePercent <= 500, "Platform fee cannot exceed 5%");
        platformFeePercent = _platformFeePercent;
    }
    
    /**
     * @dev Sets the platform address
     * @param _platformAddress New platform address
     */
    function setPlatformAddress(address _platformAddress) external onlyOwner {
        require(_platformAddress != address(0), "Invalid platform address");
        platformAddress = _platformAddress;
    }
    
    /**
     * @dev Gets info about a market
     * @param _marketId ID of the market
     * @return creator Address of the market creator
     * @return metadata JSON string with market details
     * @return startTime Start time of the market
     * @return endTime End time of the market
     * @return totalYesShares Total number of YES shares
     * @return totalNoShares Total number of NO shares
     * @return status Status of the market
     * @return finalResult Final result of the market
     */
    function getMarketInfo(uint256 _marketId) external view returns (
        address creator,
        string memory metadata,
        uint256 startTime,
        uint256 endTime,
        uint256 totalYesShares,
        uint256 totalNoShares,
        MarketStatus status,
        ResolverVote finalResult
    ) {
        Market storage market = markets[_marketId];
        
        return (
            market.creator,
            market.metadata,
            market.startTime,
            market.endTime,
            market.totalYesShares,
            market.totalNoShares,
            market.status,
            market.finalResult
        );
    }
    
    /**
     * @dev Gets vote counts for a market
     * @param _marketId ID of the market
     * @return yesVotes Number of Yes votes
     * @return noVotes Number of No votes
     * @return invalidVotes Number of Invalid votes
     */
    function getMarketVotes(uint256 _marketId) external view returns (
        uint256 yesVotes,
        uint256 noVotes,
        uint256 invalidVotes
    ) {
        Market storage market = markets[_marketId];
        
        return (
            market.yesVotes,
            market.noVotes,
            market.invalidVotes
        );
    }
    
    /**
     * @dev Gets count of active markets
     * @return count Number of active markets
     */
    function getActiveMarketsCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < marketIds.length; i++) {
            if (markets[marketIds[i]].status == MarketStatus.Active) {
                count++;
            }
        }
        return count;
    }
    
    /**
     * @dev Receive function to accept ETH payments
     */
    receive() external payable {}
    
    /**
     * @dev Fallback function
     */
    fallback() external payable {}
    
    function getCurrentBlockTimestamp() public view returns (uint256) {
        return block.timestamp;
    }

}