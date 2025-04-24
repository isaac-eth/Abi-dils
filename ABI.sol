// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Dealers {
    using SafeERC20 for IERC20;

    enum PaymentMethod { Ether, USDC }

    struct Deal {
        uint256 id;
        address payable seller;
        uint256 productCost;
        uint256 commissionAmount;
        uint256 individualCommissionAmount;
        address buyer;
        bool isPaid;
        bool isReleased;
        PaymentMethod paymentMethod;
    }

    address public owner;
    address public commissionWallet;
    uint256 public commissionRate;
    address public immutable usdcAddress;
    uint256 public etherCommissionBalance;
    uint256 public usdcCommissionBalance;

    mapping(uint256 => Deal) public deals;
    mapping(address => uint256[]) public sellerDeals;
    mapping(address => uint256[]) public buyerDeals;
    uint256 public dealCounter;

    event DealCreated(
        address indexed seller,
        PaymentMethod paymentMethod,
        uint256 productCost,
        uint256 commissionAmount,
        uint256 individualCommissionAmount,
        uint256 dealId
    );

    event DealPaid(
        address indexed seller,
        address indexed buyer,
        PaymentMethod paymentMethod,
        uint256 productCost,
        uint256 commissionAmount,
        uint256 individualCommissionAmount,
        uint256 dealId
    );

    event PaymentReleased(
        address indexed seller,
        address indexed buyer,
        PaymentMethod paymentMethod,
        uint256 productCost,
        uint256 commissionAmount,
        uint256 individualCommissionAmount,
        uint256 dealId
    );

    event CommissionWalletUpdated(address indexed newWallet);
    event CommissionRateUpdated(uint256 newRate);
    event CommissionWithdrawnETH(uint256 amount);
    event CommissionWithdrawnUSDC(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyCommissionWallet() {
        require(msg.sender == commissionWallet, "Not authorized");
        _;
    }

    constructor(address _usdcAddress) {
        require(_usdcAddress != address(0), "Invalid USDC address");
        usdcAddress = _usdcAddress;
        owner = msg.sender;
        commissionWallet = msg.sender;
        commissionRate = 250; // 2.5%
    }

    function updateCommissionWallet(address _newWallet) external onlyOwner {
        require(_newWallet != address(0), "Invalid address");
        commissionWallet = _newWallet;
        emit CommissionWalletUpdated(_newWallet);
    }

    function updateCommissionRate(uint256 _newRate) external onlyOwner {
        require(_newRate <= 10000, "Max 100%");
        commissionRate = _newRate;
        emit CommissionRateUpdated(_newRate);
    }

    function withdrawCommissionETH() external onlyCommissionWallet {
        uint256 amount = etherCommissionBalance;
        require(amount > 0, "No ETH commission");
        etherCommissionBalance = 0;
        payable(commissionWallet).transfer(amount);
        emit CommissionWithdrawnETH(amount);
    }

    function withdrawCommissionUSDC() external onlyCommissionWallet {
        uint256 amount = usdcCommissionBalance;
        require(amount > 0, "No USDC commission");
        usdcCommissionBalance = 0;
        IERC20(usdcAddress).safeTransfer(commissionWallet, amount);
        emit CommissionWithdrawnUSDC(amount);
    }

    function createDeal(uint256 _productCost, PaymentMethod _paymentMethod) external payable {
        require(_productCost > 0, "Invalid product cost");
        require(uint8(_paymentMethod) <= uint8(PaymentMethod.USDC), "Invalid payment method");

        uint256 commission = (_productCost * commissionRate) / 10000;
        uint256 individualFee = commission / 2;

        if (_paymentMethod == PaymentMethod.Ether) {
            require(msg.value == individualFee, string(
                abi.encodePacked("Must pay fee: ", uintToString(individualFee))
            ));
            etherCommissionBalance += individualFee;
        } else {
            uint256 allowance = IERC20(usdcAddress).allowance(msg.sender, address(this));
            require(allowance >= individualFee, string(
                abi.encodePacked("Must pay Fee ", uintToString(individualFee))
            ));
            IERC20(usdcAddress).safeTransferFrom(msg.sender, address(this), individualFee);
            usdcCommissionBalance += individualFee;
        }

        deals[dealCounter] = Deal({
            id: dealCounter,
            seller: payable(msg.sender),
            productCost: _productCost,
            commissionAmount: commission,
            individualCommissionAmount: individualFee,
            buyer: address(0),
            isPaid: false,
            isReleased: false,
            paymentMethod: _paymentMethod
        });

        sellerDeals[msg.sender].push(dealCounter);
        emit DealCreated(msg.sender, _paymentMethod, _productCost, commission, individualFee, dealCounter);
        dealCounter++;
    }

    function payDeal(uint256 _dealId) external payable {
        Deal storage deal = deals[_dealId];
        require(deal.seller != address(0), "Deal does not exist");
        require(!deal.isPaid, "Already paid");

        uint256 totalPayment = deal.productCost + deal.individualCommissionAmount;

        if (deal.paymentMethod == PaymentMethod.Ether) {
            require(msg.value == totalPayment, string(
                abi.encodePacked("Total payment is ", uintToString(deal.productCost), " + ", uintToString(deal.individualCommissionAmount))
            ));
            etherCommissionBalance += deal.individualCommissionAmount;
        } else {
            require(msg.value == 0, "Don't send ETH for USDC");
            uint256 allowance = IERC20(usdcAddress).allowance(msg.sender, address(this));
            require(allowance >= totalPayment, string(
                abi.encodePacked("Total payment is ", uintToString(deal.productCost), " + ", uintToString(deal.individualCommissionAmount))
            ));
            IERC20(usdcAddress).safeTransferFrom(msg.sender, address(this), totalPayment);
            usdcCommissionBalance += deal.individualCommissionAmount;
        }

        deal.buyer = msg.sender;
        deal.isPaid = true;
        buyerDeals[msg.sender].push(_dealId);
        emit DealPaid(deal.seller, msg.sender, deal.paymentMethod, deal.productCost, deal.commissionAmount, deal.individualCommissionAmount, deal.id);
    }

    function releasePayment(uint256 _dealId) external {
        Deal storage deal = deals[_dealId];
        require(deal.isPaid, "Not paid");
        require(!deal.isReleased, "Already released");
        require(msg.sender == deal.buyer, "Only buyer can release");

        deal.isReleased = true;

        if (deal.paymentMethod == PaymentMethod.Ether) {
            (bool success, ) = deal.seller.call{value: deal.productCost}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(usdcAddress).safeTransfer(deal.seller, deal.productCost);
        }

        emit PaymentReleased(deal.seller, deal.buyer, deal.paymentMethod, deal.productCost, deal.commissionAmount, deal.individualCommissionAmount, deal.id);
    }

    function getDeal(uint256 _dealId) external view returns (Deal memory) {
        return deals[_dealId];
    }

    function seeMyCreatedDeals() external view returns (Deal[] memory) {
        uint256[] storage dealIds = sellerDeals[msg.sender];
        Deal[] memory result = new Deal[](dealIds.length);
        for (uint256 i = 0; i < dealIds.length; i++) {
            result[i] = deals[dealIds[i]];
        }
        return result;
    }

    function seeMyPaidDeals() external view returns (Deal[] memory) {
        uint256[] storage dealIds = buyerDeals[msg.sender];
        Deal[] memory result = new Deal[](dealIds.length);
        for (uint256 i = 0; i < dealIds.length; i++) {
            result[i] = deals[dealIds[i]];
        }
        return result;
    }

    function getMyCreatedDealIds() external view returns (uint256[] memory) {
        return sellerDeals[msg.sender];
    }

    function getMyPaidDealIds() external view returns (uint256[] memory) {
        return buyerDeals[msg.sender];
    }

    function getAllDeals() external view returns (Deal[] memory allDeals) {
        allDeals = new Deal[](dealCounter);
        for (uint256 i = 0; i < dealCounter; i++) {
            allDeals[i] = deals[i];
        }
    }

    function getDealPaymentDetails(uint256 _dealId) external view returns (
        PaymentMethod method,
        uint256 productCost,
        uint256 commissionAmount,
        uint256 individualCommissionAmount
    ) {
        Deal storage deal = deals[_dealId];
        require(deal.seller != address(0), "Deal does not exist");
        return (deal.paymentMethod, deal.productCost, deal.commissionAmount, deal.individualCommissionAmount);
    }

    function getContractBalanceETH() external view returns (uint256) {
        return address(this).balance;
    }

    function getCommissionBalances() external view returns (uint256 ethCommission, uint256 usdcCommission) {
        return (etherCommissionBalance, usdcCommissionBalance);
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }

    receive() external payable {}
}
