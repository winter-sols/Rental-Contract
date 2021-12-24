//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "./interfaces/IERC721URI.sol";

contract wNFT is ERC721Enumerable, Ownable {
    enum WrapStatus {
        FREE,
        REQUEST_PENDING,
        RENTED,
        VIOLATED
    }

    enum Violation {
        STOP_RENT,
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

    /// @dev service fee percentage
    uint256 serviceFeeRatio;

    event Registered(address owner, address nftAddr, uint256 tokenId);

    event RentRequested(address renter, address owner, uint256 tokenId, Wrap data);

    event RentStarted(address renter, address owner, uint256 tokenId, Wrap data);

    event RentDenied(address renter, address owner, uint256 tokenId, Wrap data);

    /**
     * @dev constructor
     */
    constructor(uint256 _serviceFee)
        ERC721("wNFT", "wNFT") Ownable()
    {
        require(_serviceFee < 100, "wNFT: invalid service fee");
        serviceFee = _serviceFee;
    }

    modifier onlyValidToken(uint256 tokenId) {
        require(_exists(tokenId), "wNFT: invalid wrap token id");
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
    ) external payable {
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

        require(tokenStatus(tokenId) == WrapStatus.Free, "wNFT: cannot unregister non free wrap");
        require(wrap.owner == msg.sender, "wNFT: only token owner can unregister");

        _burn(tokenId);
        tokenId = wrap.tokenId;
        delete wrap;
        wrap.nftAddr.safeTransferFrom(address(this), msg.sender, tokenId);

        emit Unregistered(msg.sender, wrap.nftAddr, tokenId);
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
        payable
    {
        Wrap storage wrap = wraps[tokenId];

        require(tokenStatus(tokenId) == WrapStatus.FREE, "wNFT: token in rent");
        require(wrap.minRentalPeriod < rentalPeriod, "wNFT: out of rental period");
        require(wrap.maxRentalPeriod > rentalPeriod, "wNFT: out of rental period");
        require(msg.value == rentalPeriod * wrap.dailyRate, "wNFT: invalid upfront amount");

        wrap.rentalPeriod = rentalPeriod;
        wrap.renter = msg.sender;

        emit RentRequested(msg.sender, owner, tokenId, wrap);
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
            delete wrap.renter;
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
        uint256 ownerPenaltyRatio
    ) external onlyOwner onlyValidToken(tokenId) {
        require(tokenStatus(tokenId) == WrapStatus.VIOLATED, "wNFT: only violated token");

        Wrap storage wrap = wraps[tokenId];
        address renter = wrap.renter;
        address owner = wrap.owner;

        uint256 rentalFee = wrap.rentalPeriod * wrap.dailyRate;

        if (judgement == Violation.STOP_RENT) {

        } else if (judgement == Violation.RENTER_VIOLATION) {
            delete wrap.renter;

            uint256 securityDeposit = rentalFee * wrap.securityDepositRatio / 100;
            _transfer(renter, address(this), tokenId);

            payable(renter).call{value: rentalFee - securityDeposit}("");
            payable(owner).call{value: excludeServiceFeeFrom(securityDeposit)}("");

            emit RenterViolated(renter, owner, tokenId);
        } else { // OWNER_VIOLATION
            uint256 ownerPenalty = rentalFee * ownerPenaltyRatio / 100;

            payable(renter).call{value: excludeServiceFeeFrom(ownerPenalty)}("");
            // ask owner to pay penalty
            if (judgement == Violation.OWNER_SERIOUS_VIOLATION) {
                uint256 originTokenId = wrap.tokenId;
                _burn(tokenId);
                delete wrap;
                wrap.nftAddr.safeTransferFrom(address(this), owner, wrap.tokenId);
                emit OwnerSeriouslyViolated(renter, owner, tokenId, originTokenId);
            } else {
                delete wrap.renter;
                _transfer(renter, address(this), tokenId);
                emit OwnerViolated(renter, owner, tokenId);
            }
        }
    }

    function excludeServiceFeeFrom(uint256 amount) pure public returns (uint256) {
        return amount - amount * serviceFeeRatio / 100;
    }

    function tokenURI(uint256 tokenId)
        external
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
        require(tokenStatus(tokenId) == WrapStatus.FREE, "wNFT: not transferrable");
        ERC721._transfer(from, to, tokenId);
    }
}
