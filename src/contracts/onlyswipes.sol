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
        
        // New fields for tracking bettors
        mapping(address => bool) isBettor;
        address[] bettorAddresses;
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
    
    // New debug events
    event DistributionDebug(uint256 marketId, uint256 totalPool, uint256 winnersCount);
    event WinnerDebug(uint256 marketId, address winner, uint256 shares, bool success);
    
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
 * @param _creatorAddress Address that will receive creator fees (useful for smart wallets)
 * @return marketId ID of the newly created market
 */
function createMarket(
    string calldata _metadata,
    uint256 _startTime,
    uint256 _endTime,
    uint256 _creatorFee,
    address _creatorAddress
) external returns (uint256 marketId) {
    require(_startTime > block.timestamp, "Start time must be in the future");
    require(_endTime > _startTime, "End time must be after start time");
    require(_creatorFee <= 500, "Creator fee cannot exceed 5%");
    
    // Use the specified creator address if provided, otherwise use msg.sender
    address creator = _creatorAddress == address(0) ? msg.sender : _creatorAddress;
    
    marketId = totalMarkets;
    
    Market storage newMarket = markets[marketId];
    newMarket.creator = creator;
    newMarket.metadata = _metadata;
    newMarket.startTime = _startTime;
    newMarket.endTime = _endTime;
    newMarket.creatorFee = _creatorFee;
    newMarket.status = MarketStatus.Active;
    newMarket.finalResult = ResolverVote.None;
    
    marketIds.push(marketId);
    totalMarkets++;
    
    emit MarketCreated(marketId, creator, _metadata, _startTime, _endTime);
    
    return marketId;
}
    
    /**
     * @dev Buys shares in a market prediction
     * @param _marketId ID of the market
     * @param _direction Direction of the bet (Yes or No)
     * @param _shares Number of shares to buy
     * @param _walletAddress Address that will own the shares (useful for smart wallets)
     */
    function buyShares(
        uint256 _marketId,
        BetDirection _direction,
        uint256 _shares,
        address _walletAddress
    ) external payable nonReentrant {
        Market storage market = markets[_marketId];
        
        // Use the specified wallet address if provided, otherwise use msg.sender
        address bettor = _walletAddress == address(0) ? msg.sender : _walletAddress;
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Active, "Market is not active");
        require(block.timestamp >= market.startTime, "Market has not started yet");
        require(block.timestamp < market.endTime, "Market has ended");
        require(_shares > 0, "Must buy at least one share");
        
        // Calculate required ETH amount
        uint256 requiredAmount = _shares * sharePrice;
        
        // Ensure correct ETH amount was sent
        require(msg.value == requiredAmount, "Incorrect ETH amount sent");
        
        // Track bettor if not already tracked
        if (!market.isBettor[bettor]) {
            market.isBettor[bettor] = true;
            market.bettorAddresses.push(bettor);
        }
        
        // Update market stats
        if (_direction == BetDirection.Yes) {
            market.yesShares[bettor] += _shares;
            market.totalYesShares += _shares;
        } else {
            market.noShares[bettor] += _shares;
            market.totalNoShares += _shares;
        }
        
        emit SharesBought(_marketId, bettor, _direction, _shares, requiredAmount);
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
     * @param _walletAddress Address that will be associated with the resolver (useful for smart wallets)
     */
    function stakeAsResolver(address _walletAddress) external payable nonReentrant {
        // Use the specified wallet address if provided, otherwise use msg.sender
        address resolver = _walletAddress == address(0) ? msg.sender : _walletAddress;
        
        require(resolvers[resolver].isActive == false, "Already an active resolver");
        require(msg.value == RESOLVER_STAKE_AMOUNT, "Incorrect stake amount");
        
        // Update resolver info
        resolvers[resolver] = Resolver({
            stakedAmount: RESOLVER_STAKE_AMOUNT,
            stakingTime: block.timestamp,
            isActive: true
        });
        
        // Add to resolver address array if not already tracked
        if (!isKnownResolver[resolver]) {
            resolverAddressArray.push(resolver);
            isKnownResolver[resolver] = true;
        }
        
        emit ResolverStaked(resolver, RESOLVER_STAKE_AMOUNT);
    }
    
    /**
     * @dev Unstakes ETH and removes resolver status
     * @param _walletAddress Address of the resolver to unstake (useful for smart wallets)
     */
    function unstakeAsResolver(address _walletAddress) external nonReentrant {
        // Use the specified wallet address if provided, otherwise use msg.sender
        address resolver = _walletAddress == address(0) ? msg.sender : _walletAddress;
        
        // Verify caller is authorized (must be either the resolver or msg.sender must be the resolver)
        require(resolver == msg.sender || resolvers[resolver].isActive, "Not authorized");
        
        Resolver storage resolverData = resolvers[resolver];
        
        require(resolverData.isActive, "Not an active resolver");
        require(resolverData.stakedAmount > 0, "No stake to withdraw");
        
        uint256 amountToReturn = resolverData.stakedAmount;
        
        // Update resolver info
        resolverData.stakedAmount = 0;
        resolverData.isActive = false;
        
        // Transfer ETH back to resolver
        (bool success, ) = resolver.call{value: amountToReturn}("");
        require(success, "ETH transfer failed");
        
        emit ResolverUnstaked(resolver, amountToReturn);
    }
    
    /**
     * @dev Votes on a market's outcome (resolvers only)
     * @param _marketId ID of the market
     * @param _vote Vote (Yes, No, or Invalid)
     * @param _walletAddress Address of the resolver voting (useful for smart wallets)
     */
    function voteOnMarket(uint256 _marketId, ResolverVote _vote, address _walletAddress) external {
        require(_vote != ResolverVote.None, "Invalid vote option");
        
        // Use the specified wallet address if provided, otherwise use msg.sender
        address resolver = _walletAddress == address(0) ? msg.sender : _walletAddress;
        
        // Verify caller is authorized
        require(resolver == msg.sender || resolvers[resolver].isActive, "Not authorized");
        
        Market storage market = markets[_marketId];
        Resolver storage resolverData = resolvers[resolver];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Closed, "Market must be closed for voting");
        require(resolverData.isActive, "Not an active resolver");
        require(resolverData.stakingTime < market.startTime, "Must have staked before market started");
        require(!market.hasVoted[resolver], "Already voted on this market");
        
        // Record the vote
        market.hasVoted[resolver] = true;
        market.resolverVotes[resolver] = _vote;
        
        // Update vote counts
        if (_vote == ResolverVote.Yes) {
            market.yesVotes++;
        } else if (_vote == ResolverVote.No) {
            market.noVotes++;
        } else if (_vote == ResolverVote.Invalid) {
            market.invalidVotes++;
        }
        
        emit ResolverVoted(_marketId, resolver, _vote);
        
        // Check if we have a majority to finalize
        checkAndFinalizeMarket(_marketId);
    }
    
    /**
     * @dev Claims winnings from a resolved market
     * @param _marketId ID of the market
     * @param _walletAddress Address of the bettor claiming winnings (useful for smart wallets)
     */
    function claimWinnings(uint256 _marketId, address _walletAddress) external nonReentrant {
        // Use the specified wallet address if provided, otherwise use msg.sender
        address bettor = _walletAddress == address(0) ? msg.sender : _walletAddress;
        
        // Verify caller is authorized
        require(bettor == msg.sender || 
                markets[_marketId].yesShares[bettor] > 0 || 
                markets[_marketId].noShares[bettor] > 0, 
                "Not authorized");
        
        Market storage market = markets[_marketId];
        
        require(market.creator != address(0), "Market does not exist");
        require(market.status == MarketStatus.Resolved, "Market is not resolved");
        
        uint256 winningAmount = 0;
        
        if (market.finalResult == ResolverVote.Invalid) {
            // Return original bets if market is invalid
            uint256 yesSharesValue = market.yesShares[bettor] * sharePrice;
            uint256 noSharesValue = market.noShares[bettor] * sharePrice;
            winningAmount = yesSharesValue + noSharesValue;
            
            // Reset user's shares
            market.yesShares[bettor] = 0;
            market.noShares[bettor] = 0;
        } else {
            bool userHasWinningShares = false;
            uint256 userWinningShares = 0;
            uint256 totalWinningShares = 0;
            uint256 totalPoolValue = (market.totalYesShares + market.totalNoShares) * sharePrice;
            
            // Determine if user has winning shares and how many
            if (market.finalResult == ResolverVote.Yes && market.yesShares[bettor] > 0) {
                userHasWinningShares = true;
                userWinningShares = market.yesShares[bettor];
                totalWinningShares = market.totalYesShares;
                // Reset user's shares
                market.yesShares[bettor] = 0;
            } else if (market.finalResult == ResolverVote.No && market.noShares[bettor] > 0) {
                userHasWinningShares = true;
                userWinningShares = market.noShares[bettor];
                totalWinningShares = market.totalNoShares;
                // Reset user's shares
                market.noShares[bettor] = 0;
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
            (bool success, ) = bettor.call{value: winningAmount}("");
            require(success, "Winnings transfer failed");
            emit WinningsClaimed(_marketId, bettor, winningAmount);
        }
    }
    
    /**
     * @dev Checks if a market can be finalized based on resolver votes and distributes winnings if resolved
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
        
        // AUTO-DISTRIBUTE WINNINGS TO ALL WINNERS
        distributeWinnings(_marketId);
    }

    /**
     * @dev Automatically distributes winnings to all winners of a resolved market
     * @param _marketId ID of the market
     */
    function distributeWinnings(uint256 _marketId) internal {
        Market storage market = markets[_marketId];
        require(market.status == MarketStatus.Resolved, "Market is not resolved");
        
        // Calculate total pool value
        uint256 totalPoolValue = (market.totalYesShares + market.totalNoShares) * sharePrice;
        
        // Get winning side details
        uint256 totalWinningShares;
        address[] memory winners;
        uint256[] memory winningShares;
        uint256 winnerCount = 0;
        
        // First pass: Count winners and get winning shares
        if (market.finalResult == ResolverVote.Invalid) {
            // In case of INVALID result, everyone gets their money back
            // Use bettor addresses array instead of resolver array
            winners = new address[](market.bettorAddresses.length * 2); // Max possible size
            winningShares = new uint256[](market.bettorAddresses.length * 2);
            
            for (uint256 i = 0; i < market.bettorAddresses.length; i++) {
                address addr = market.bettorAddresses[i];
                
                // Check YES shares
                if (market.yesShares[addr] > 0) {
                    winners[winnerCount] = addr;
                    winningShares[winnerCount] = market.yesShares[addr] * sharePrice; // Direct return of investment
                    winnerCount++;
                }
                
                // Check NO shares separately (same user might have both)
                if (market.noShares[addr] > 0) {
                    winners[winnerCount] = addr;
                    winningShares[winnerCount] = market.noShares[addr] * sharePrice; // Direct return of investment
                    winnerCount++;
                }
            }
        } else if (market.finalResult == ResolverVote.Yes) {
            // YES won, distribute to YES bettors
            totalWinningShares = market.totalYesShares;
            winners = new address[](market.bettorAddresses.length);
            winningShares = new uint256[](market.bettorAddresses.length);
            
            for (uint256 i = 0; i < market.bettorAddresses.length; i++) {
                address addr = market.bettorAddresses[i];
                if (market.yesShares[addr] > 0) {
                    winners[winnerCount] = addr;
                    winningShares[winnerCount] = market.yesShares[addr];
                    winnerCount++;
                }
            }
        } else if (market.finalResult == ResolverVote.No) {
            // NO won, distribute to NO bettors
            totalWinningShares = market.totalNoShares;
            winners = new address[](market.bettorAddresses.length);
            winningShares = new uint256[](market.bettorAddresses.length);
            
            for (uint256 i = 0; i < market.bettorAddresses.length; i++) {
                address addr = market.bettorAddresses[i];
                if (market.noShares[addr] > 0) {
                    winners[winnerCount] = addr;
                    winningShares[winnerCount] = market.noShares[addr];
                    winnerCount++;
                }
            }
        }
        
        // Debug event to track distribution start
        emit DistributionDebug(_marketId, totalPoolValue, winnerCount);
        
        // Second pass: Distribute winnings to each winner
        for (uint256 i = 0; i < winnerCount; i++) {
            address winner = winners[i];
            uint256 shares = winningShares[i];
            uint256 winningAmount = 0;
            
            if (market.finalResult == ResolverVote.Invalid) {
                // For Invalid results, winningAmount is already calculated above
                winningAmount = shares;
            } else {
                // Pari-mutuel calculation
                winningAmount = (shares * totalPoolValue) / totalWinningShares;
                
                // Calculate and deduct fees
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
            
            // Reset user's shares to prevent double claiming
            if (market.finalResult == ResolverVote.Yes || market.finalResult == ResolverVote.Invalid) {
                market.yesShares[winner] = 0;
            }
            if (market.finalResult == ResolverVote.No || market.finalResult == ResolverVote.Invalid) {
                market.noShares[winner] = 0;
            }
            
            // Transfer winnings
            if (winningAmount > 0) {
                (bool success, ) = winner.call{value: winningAmount}("");
                // Debug event for each transfer
                emit WinnerDebug(_marketId, winner, winningAmount, success);
                
                // Don't revert the entire transaction if one transfer fails
                if (success) {
                    emit WinningsClaimed(_marketId, winner, winningAmount);
                }
            }
        }
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
     * @dev Gets the bettor addresses for a market
     * @param _marketId ID of the market
     * @return Array of bettor addresses
     */
    function getMarketBettors(uint256 _marketId) external view returns (address[] memory) {
        return markets[_marketId].bettorAddresses;
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
     * @dev Manually force distribution of winnings for a specific market
     * @param _marketId ID of the market
     */
    function forceDistributeWinnings(uint256 _marketId) external onlyOwner {
        Market storage market = markets[_marketId];
        require(market.status == MarketStatus.Resolved, "Market is not resolved");
        
        distributeWinnings(_marketId);
    }
    
    /**
     * @dev Receive function to accept ETH payments
     */
    receive() external payable {}
    
    /**
     * @dev Fallback function
     */
    fallback() external payable {}
    
    /**
     * @dev Get current block timestamp
     */
    function getCurrentBlockTimestamp() public view returns (uint256) {
        return block.timestamp;
    }
}