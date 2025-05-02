// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

error InsufficientBalance(uint256 err);
error AddressZero(uint256 err);
error TransferFailed(uint256 err);

contract SwyptPool is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable
{
    uint256 private constant INSUFFICIENT_BALANCE = 0;
    uint256 private constant ADDRESS_ZERO = 1;
    uint256 private constant TRANSFER_FAILED = 2;

    address public beneficiary;
    uint256 public depositNonce;

    struct DepositInfo {
        address token;
        address user;
        uint256 amount;
        uint256 exchangeRate;
        uint256 feeAmount;
    }

    mapping(uint256 => DepositInfo) private depositInfo;
    mapping(address => bool) public isWhitelistedAsset;
    address[] private tokens;

    event Deposited(
        address user,
        address token,
        uint256 indexed amount,
        uint256 indexed nonce,
        uint256 indexed exchangeRate,
        uint256 feeAmount
    );
    event Refunded(address indexed user, address indexed token, uint256 amount);
    event FundsWithdrawn(
        address indexed tokenAddress,
        address indexed beneficiary,
        uint256 amount
    );
    event BeneficiaryUpdated(address newBeneficiary);
    event NativeTokenDeposited(address indexed user, uint256 amount);

    modifier onlyModuleAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Not authorized");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() initializer {}

    function initialize(
        address _defaultAdmin,
        address _beneficiary
    ) external initializer {
        UUPSUpgradeable.__UUPSUpgradeable_init();
        OwnableUpgradeable.__Ownable_init(_msgSender());
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        PausableUpgradeable.__Pausable_init();
        AccessControlUpgradeable.__AccessControl_init();
        beneficiary = _beneficiary;
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyModuleAdmin {}

    function setBeneficiary(address _newBeneficiary) external onlyModuleAdmin {
        beneficiary = _newBeneficiary;
        emit BeneficiaryUpdated(_newBeneficiary);
    }

    //User function ||
    function withdrawWithPermit(
        address _tokenAddress,
        uint256 _amount,
        uint256 _exchangeRate,
        uint256 _feeAmount,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused nonReentrant returns (uint256 nonce) {
        IERC20Permit(_tokenAddress).permit(
            msg.sender,
            address(this),
            _amount,
            deadline,
            v,
            r,
            s
        );
        nonce = _withdrawToken(
            _tokenAddress,
            _amount,
            _exchangeRate,
            _feeAmount
        );
    }

    // Public function to initiate the withdrawal to escrow
    function withdrawToEscrow(
        address _tokenAddress,
        uint256 _amount,
        uint256 _exchangeRate,
        uint256 _feeAmount
    ) external nonReentrant payable returns (uint256 nonce) {
        nonce = _withdrawToken(
            _tokenAddress,
            _amount,
            _exchangeRate,
            _feeAmount
        );
    }

    // Internal function to handle the transfer of funds, be it ETH or ERC20
    function _withdrawToken(
        address _tokenAddress,
        uint256 amountPlusFee,
        uint256 _exchangeRate,
        uint256 _feeAmount
    ) internal returns (uint256 nonce) {
        if (_tokenAddress == address(0)) {
            // Handle ETH
            // Native token withdrawal
            if (address(msg.sender).balance < amountPlusFee) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            require(msg.value == amountPlusFee, "Incorrect ETH value");
            // Send fee to the beneficiary
            payable(beneficiary).transfer(_feeAmount);
        } else {
            // Handle ERC20
            if (IERC20(_tokenAddress).balanceOf(msg.sender) < amountPlusFee) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            IERC20(_tokenAddress).transferFrom(
                msg.sender,
                address(this),
                amountPlusFee
            );

            IERC20(_tokenAddress).transfer(beneficiary, _feeAmount);
        }

        nonce = depositNonce;

        depositInfo[nonce] = DepositInfo({
            token: _tokenAddress,
            user: msg.sender,
            amount: amountPlusFee - _feeAmount,
            exchangeRate: _exchangeRate,
            feeAmount: _feeAmount
        });

        unchecked {
            depositNonce++;
        }

        emit Deposited(
            msg.sender,
            _tokenAddress,
            amountPlusFee,
            nonce,
            _exchangeRate,
            _feeAmount
        );
    }

    //withdraws asset to designated address
    function withdrawFunds(
        address _tokenAddress,
        uint256 _amount,
        address _userAddress
    ) external whenNotPaused nonReentrant onlyModuleAdmin returns (bool) {
        if (_tokenAddress == address(0)) {
            // Native token withdrawal
            if (address(this).balance < _amount) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            (bool success, ) = _userAddress.call{value: _amount}("");
            if (!success) {
                revert TransferFailed(TRANSFER_FAILED);
            }
        } else {
            // ERC20 token withdrawal
            IERC20 _token = IERC20(_tokenAddress);
            uint256 _balance = _token.balanceOf(address(this));
            if (_balance < _amount) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            _token.transfer(_userAddress, _amount);
        }

        emit FundsWithdrawn(_tokenAddress, _userAddress, _amount);
        return true;
    }

    function refundUser(
        address _userAddress,
        address _tokenAddress,
        uint256 _amount
    ) external whenNotPaused nonReentrant onlyModuleAdmin {
        uint256 contractBalance = IERC20(_tokenAddress).balanceOf(
            address(this)
        );
        if (contractBalance < _amount) {
            revert InsufficientBalance(INSUFFICIENT_BALANCE);
        }

        IERC20(_tokenAddress).transfer(_userAddress, _amount);

        emit Refunded(_userAddress, _tokenAddress, _amount);
    }

    function depositToWallet(
        address _userAddress,
        address _token,
        uint256 _amount,
        uint256 _exchangeRate,
        uint256 _feeAmount
    ) external whenNotPaused nonReentrant onlyModuleAdmin returns (bool) {
        if (_userAddress == address(0)) {
            revert AddressZero(ADDRESS_ZERO);
        }

        if (_token == address(0)) {
            // Native token deposit
            if (address(this).balance < _amount) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            (bool success, ) = _userAddress.call{value: _amount}("");
            if (!success) {
                revert TransferFailed(TRANSFER_FAILED);
            }
            emit NativeTokenDeposited(_userAddress, _amount);
        } else {
            // ERC20 token deposit
            IERC20 token = IERC20(_token);
            uint256 balance = token.balanceOf(address(this));
            if (balance < _amount) {
                revert InsufficientBalance(INSUFFICIENT_BALANCE);
            }
            token.transfer(_userAddress, _amount);
        }

        emit Deposited(
            _userAddress,
            _token,
            _amount,
            block.timestamp,
            _exchangeRate,
            _feeAmount
        );
        return true;
    }

    function viewDepositWithNonce(
        uint256 _nonce
    )
        external
        view
        returns (
            address token,
            address user,
            uint256 amount,
            uint256 exchangeRate,
            uint256 feeAmount
        )
    {
        DepositInfo memory deposit = depositInfo[_nonce];

        token = deposit.token;
        user = deposit.user;
        amount = deposit.amount;
        exchangeRate = deposit.exchangeRate;
        feeAmount = deposit.feeAmount;
    }

    function pause() external onlyModuleAdmin {
        _pause();
    }

    function unpause() external onlyModuleAdmin {
        _unpause();
    }

    receive() external payable {}
}