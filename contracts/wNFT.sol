//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IERC721URI.sol";

contract wNFT is ERC721Enumerable, Ownable, ReentrancyGuard {
    enum WrapStatus {
        FREE,
        REQUEST_PENDING,
        RENTED,
        VIOLATED
    }

    enum Violation {
        NO_VIOLATION,
        RENTER_VIOLATION,
        OWNER_VIOLATION,
        OWNER_SERIOUS_VIOLATION
    }

    /// @dev keep original NFT data
    struct Wrap {
        IERC721URI nftAddr;
        address renter;
        address owner;
        address disputeBy;

        /// @dev min rental period in days, set by token owner
        uint256 minRentalPeriod;

        /// @dev max rental period in days, set by token owner
        uint256 maxRentalPeriod;

        /// @dev rental period in days, actually agreed between renter and owner
        uint256 rentalPeriod;

        /// @dev rent start timestamp
        uint256 rentStarted;

        uint256 securityDepositRatio;

        uint256 dailyRate;
        uint256 tokenId;
    }

    /// @dev token id tracker
    uint256 internal tokenIdTracker;

    /// @dev token id => wrap
    mapping(uint256 => Wrap) internal wraps;

    mapping(address => uint256) public ownerPenalties;

    /// @dev service fee percentage
    uint256 serviceFeeRatio;

    /// @dev service fee percentage
    uint256 serviceFee;

    event Registered(address owner, address nftAddr, uint256 tokenId);

    event RentRequested(address renter, address owner, uint256 tokenId, Wrap data);

    event RentStarted(address renter, address owner, uint256 tokenId, Wrap data);

    event RentDenied(address renter, address owner, uint256 tokenId, Wrap data);

    event Unregistered(address owner, address nftAddr, uint256 tokenId);

    event ServiceFeeRatioSet(uint256 percentage);

    event ViolationRaised(address owner, address renter, uint256 tokenId);

    event DisputeResolved(
        Violation judgement,
        address owner,
        address renter,
        address serviceFeeCollector,
        uint256 toOwner,
        uint256 toRenter,
        uint256 serviceFees,
        uint256 ownerPenalty
    );

    // event RenterViolated(address renter, address owner, uint256 tokenId);

    // event OwnerSeriouslyViolated(address renter, address owner, uint256 tokenId, uint256 originTokenId);

    // event OwnerViolated(address renter, address owner, uint256 tokenId);

    event OwnerPenaltyPaid(address serviceFeeCollector, address renter, uint256 penalty);
    
    /**
     * @dev constructor
     */
    constructor(uint256 _serviceFee)
        ERC721("wNFT", "wNFT") Ownable() ReentrancyGuard()
    {
        require(_serviceFee < 100, "wNFT: invalid service fee");
        serviceFee = _serviceFee;
    }

    modifier onlyValidToken(uint256 tokenId) {
        require(_exists(tokenId), "wNFT: invalid wrap token id");
        _;
    }

    modifier onlyLoyalOwner(address owner) {
        require(ownerPenalties[owner] == 0, "wNFT: owner has penalties");
        _;
    }

    /**
     * @dev Registers token and mint wNFT to the token owner
     * @param nftAddr token address
     * @param tokenId token id
     * @param minRentalPeriod min rental period in days
     * @param maxRentalPeriod max rental period in days
     * @param dailyRate daily rate
     */
    function register(
        address nftAddr,
        uint256 tokenId,
        uint256 minRentalPeriod,
        uint256 maxRentalPeriod,
        uint256 dailyRate,
        uint256 securityDepositRatio
    ) external payable onlyLoyalOwner(msg.sender) {
        address owner = IERC721URI(nftAddr).ownerOf(tokenId);

        require(msg.sender == owner, "wNFT: caller is not the owner of the NFT");
        require(nftAddr != address(this), "wNFT: cannot register wNFT");
        require(minRentalPeriod > 0, "wNFT: zero min rental period");
        require(maxRentalPeriod > minRentalPeriod, "wNFT: invalid max rental period");
        require(dailyRate > 0, "wNFT: zero daily rate");
        require(securityDepositRatio < 100, "wNFT: invalid security deposit ratio");

        uint256 newTokenId = tokenIdTracker;
        Wrap storage wrap = wraps[newTokenId];

        tokenIdTracker += 1;

        // store original nft data
        wrap.nftAddr = IERC721URI(nftAddr);
        wrap.owner = owner;
        wrap.tokenId = tokenId;
        wrap.minRentalPeriod = minRentalPeriod;
        wrap.maxRentalPeriod = maxRentalPeriod;
        wrap.dailyRate = dailyRate;
        wrap.securityDepositRatio = securityDepositRatio;

        // escrow the nft
        wrap.nftAddr.safeTransferFrom(owner, address(this), tokenId);

        // mint wNFT
        _safeMint(address(this), newTokenId);

        emit Registered(msg.sender, nftAddr, tokenId);
    }

    /**
     * @dev Unregisters wrap and send tokenb back to the owner
     * @param tokenId wrap token id
     */
    function unregister(uint256 tokenId) external onlyValidToken(tokenId) {
        Wrap storage wrap = wraps[tokenId];

        require(tokenStatus(tokenId) == WrapStatus.FREE, "wNFT: cannot unregister non free wrap");
        require(wrap.owner == msg.sender, "wNFT: only token owner can unregister");

        _burn(tokenId);
        tokenId = wrap.tokenId;
        delete wraps[tokenId];
        wrap.nftAddr.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Unregistered(msg.sender, address(wrap.nftAddr), tokenId);
    }

    /**
     * @dev Returns wrap token status
     * @param tokenId wrap token id
     */
    function tokenStatus(uint256 tokenId)
        public
        view
        onlyValidToken(tokenId)
        returns (WrapStatus)
    {
        Wrap storage wrap = wraps[tokenId];
        if (wrap.renter == address(0)) {
            return WrapStatus.FREE;
        } else if (wrap.rentStarted == 0) {
            return WrapStatus.REQUEST_PENDING;
        } else if (wrap.disputeBy != address(0)) {
            return WrapStatus.VIOLATED;
        } else if (wrap.rentStarted + wrap.rentalPeriod > block.timestamp) {
            return WrapStatus.FREE;
        } else {
            return WrapStatus.RENTED;
        }
    }

    /**
     * @dev Sends a rent request with upfront
     * @param tokenId wrap token id
     * @param rentalPeriod rental period in days
     */
    function requestRent(uint256 tokenId, uint256 rentalPeriod)
        external
        onlyValidToken(tokenId)
        onlyLoyalOwner(wraps[tokenId].owner)
        payable
    {
        Wrap storage wrap = wraps[tokenId];

        require(tokenStatus(tokenId) == WrapStatus.FREE, "wNFT: token in rent");
        require(wrap.minRentalPeriod < rentalPeriod, "wNFT: out of rental period");
        require(wrap.maxRentalPeriod > rentalPeriod, "wNFT: out of rental period");
        require(msg.value == rentalPeriod * wrap.dailyRate, "wNFT: invalid upfront amount");

        wrap.rentalPeriod = rentalPeriod;
        wrap.renter = msg.sender;

        emit RentRequested(msg.sender, wrap.owner, tokenId, wrap);
    }

    /**
     * @dev Approves the request rent and initiates the rent if approved
     * @param tokenId wrap token id
     * @param approve approve or deny
     */
    function approveRentRequest(uint256 tokenId, bool approve) external onlyValidToken(tokenId) {
        Wrap storage wrap = wraps[tokenId];

        require(wrap.owner == msg.sender, "wNFT: caller is not the token owner");
        require(tokenStatus(tokenId) == WrapStatus.REQUEST_PENDING, "wNFT: not requested");

        if (approve) {
            wrap.rentStarted = block.timestamp;
            _transfer(address(this), wrap.renter, tokenId);
            emit RentStarted(wrap.renter, msg.sender, tokenId, wrap);
        } else {
            // refund the upfront if the request is not approved
            payable(wrap.renter).call{value: wrap.rentalPeriod * wrap.dailyRate}("");
            wrap.renter = address(0);
            emit RentDenied(wrap.renter, msg.sender, tokenId, wrap);
        }
    }

    /**
     * @dev Sets service fee ratio
     * @param percentage ratio
     */
    function setServiceFeeRatio(uint256 percentage) external onlyOwner {
        require(percentage < 100, "wNFT: invalid service fee");
        serviceFeeRatio = percentage;

        emit ServiceFeeRatioSet(percentage);
    }

    function raiseViolation(uint256 tokenId) external onlyValidToken(tokenId) {
        Wrap storage wrap = wraps[tokenId];

        require(tokenStatus(tokenId) == WrapStatus.RENTED, "wNFT: non rented token");
        require(msg.sender == wrap.owner || msg.sender == wrap.renter, "wNFT: only rental contractors");

        wrap.disputeBy = msg.sender;

        emit ViolationRaised(wrap.owner, wrap.renter, tokenId);
    }

    /**
     * @dev Disposes dispute
     * @param tokenId wrap token id
     * @param judgement judgement
     * @param ownerPenaltyRatio owner penalty ratio if judgement is OWNER_VIOLATION or OWNER_SERIOUS_VIOLATION
     */
    function disposeDispute(
        uint256 tokenId,
        Violation judgement,
        uint256 decisionPaymentRatio,
        uint256 ownerPenaltyRatio
    ) external onlyOwner onlyValidToken(tokenId) nonReentrant() {
        require(tokenStatus(tokenId) == WrapStatus.VIOLATED, "wNFT: only violated token");
        require(decisionPaymentRatio > 100, "wNFT: invalid decision payment ratio");
        require(ownerPenaltyRatio > 100, "wNFT: invalid downer penalty ratio");

        Wrap storage wrap = wraps[tokenId];
        address renter = wrap.renter;
        address owner = wrap.owner;
        address serviceFeeCollector = address(this);
        uint256 rentalFee = wrap.rentalPeriod * wrap.dailyRate;

        _endRent(tokenId);

        if (wrap.disputeBy == wrap.renter) {
            if (judgement == Violation.OWNER_VIOLATION || judgement == Violation.OWNER_SERIOUS_VIOLATION) {
                uint256 ownerPenalty = rentalFee * ownerPenaltyRatio / 100;
                uint256 decidedRentalFee = rentalFee * decisionPaymentRatio / 100;
                uint256 toOwner = excludeServiceFeeFrom(decidedRentalFee);
                uint256 serviceFees = decidedRentalFee - toOwner;
                uint256 toRenter = rentalFee - decidedRentalFee;

                ownerPenalties[owner] += ownerPenalty;

                payable(owner).call{value: toOwner}("");
                payable(renter).call{value: toRenter}("");
                payable(serviceFeeCollector).call{value: serviceFees}("");

                emit DisputeResolved(
                    judgement,
                    wrap.owner,
                    wrap.renter,
                    serviceFeeCollector,
                    toOwner,
                    toRenter,
                    serviceFees,
                    ownerPenalty
                );
            } else if (judgement == Violation.NO_VIOLATION) {
                uint256 toOwner = excludeServiceFeeFrom(rentalFee);
                uint256 decidedRentalFee = rentalFee * decisionPaymentRatio / 100;
                uint256 toRenter = rentalFee - decidedRentalFee;
                uint256 serviceFees = rentalFee - toOwner;

                payable(wrap.owner).call{value: toOwner}("");
                payable(serviceFeeCollector).call{value: serviceFees}("");

                emit DisputeResolved(
                    judgement,
                    wrap.owner,
                    wrap.renter,
                    serviceFeeCollector,
                    toOwner,
                    toRenter,
                    serviceFees,
                    0
                );
            } else {
                revert('wNFT: invalid judgement');
            }
        } else {
            if (judgement == Violation.RENTER_VIOLATION) {

            } else if (judgement == Violation.NO_VIOLATION) {
                uint256 toOwner = excludeServiceFeeFrom(rentalFee);
                uint256 decidedRentalFee = rentalFee * decisionPaymentRatio / 100;
                uint256 toRenter = rentalFee - decidedRentalFee;
                uint256 serviceFees = rentalFee - toOwner;

                payable(wrap.owner).call{value: toOwner}("");
                payable(serviceFeeCollector).call{value: serviceFees}("");

                emit DisputeResolved(
                    judgement,
                    wrap.owner,
                    wrap.renter,
                    serviceFeeCollector,
                    toOwner,
                    toRenter,
                    serviceFees,
                    0
                );
            } else {
                revert('wNFT: invalid judgement');
            }
        }

        // if (judgement == Violation.RENTER_VIOLATION) {
        //     wrap.renter = address(0);

        //     uint256 securityDeposit = rentalFee * wrap.securityDepositRatio / 100;
        //     _transfer(renter, address(this), tokenId);

        //     payable(renter).call{value: rentalFee - securityDeposit}("");
        //     payable(owner).call{value: excludeServiceFeeFrom(securityDeposit)}("");

        //     emit RenterViolated(renter, owner, tokenId);
        // } else if (judgement == Violation.OWNER_VIOLATION) {
        //     uint256 ownerPenalty = rentalFee * ownerPenaltyRatio / 100;

        //     payable(renter).call{value: excludeServiceFeeFrom(ownerPenalty)}("");
        //     // ask owner to pay penalty
        //     if (judgement == Violation.OWNER_SERIOUS_VIOLATION) {
        //         uint256 originTokenId = wrap.tokenId;
        //         _burn(tokenId);
        //         delete wraps[tokenId];
        //         wrap.nftAddr.safeTransferFrom(address(this), owner, wrap.tokenId);
        //         emit OwnerSeriouslyViolated(renter, owner, tokenId, originTokenId);
        //     } else {
        //         wrap.renter = address(0);
        //         _transfer(renter, address(this), tokenId);
        //         emit OwnerViolated(renter, owner, tokenId);
        //     }
        // }
    }

    function excludeServiceFeeFrom(uint256 amount) public view returns (uint256) {
        return amount - amount * serviceFeeRatio / 100;
    }

    function _endRent(uint256 tokenId) internal {
        Wrap storage wrap = wraps[tokenId];
        _transfer(wrap.renter, address(this), tokenId);
        wrap.renter = address(0);
    }

    function payPenalty() external onlyOwner payable {
        uint256 penalty = ownerPenalties[msg.sender];
        address serviceFeeCollector = owner();

        require(msg.value == penalty, "wNFT: incorrect amount");
        ownerPenalties[msg.sender] = 0;


        serviceFeeCollector.call{value: penalty}("");

        emit OwnerPenaltyPaid(address(serviceFeeCollector), msg.sender, penalty);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        onlyValidToken(tokenId)
        returns (string memory)
    {
        Wrap storage wrap = wraps[tokenId];
        return wrap.nftAddr.tokenURI(wrap.tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal override {
        WrapStatus status = tokenStatus(tokenId);

        Wrap storage wrap = wraps[tokenId];
        string memory err = "wNFT: invalid transfer";

        if (status == WrapStatus.REQUEST_PENDING) {
            require(from == address(this), err);
            require(to == wrap.renter, err);
        } else if (status == WrapStatus.FREE) {
            require(from == wrap.renter, err);
            require(to == address(this), err);
        }

        ERC721._transfer(from, to, tokenId);
    }
}
