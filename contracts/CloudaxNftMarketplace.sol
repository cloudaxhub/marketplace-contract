// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "./CloudaxNFT.sol";

////Custom Errors
error InvalidAddress();
error QuantityRequired(uint256 quantity, uint256 minRequired);
error QuantityDoesNotExist(uint256 availableQuantity);
error InvalidItemId(uint256 itemId);
error ItemSoldOut(uint256 quantity, uint256 numSold);
error InsufficientFund(uint256 price, uint256 allowedFund);

contract CloudaxNftMarketplace is
    ReentrancyGuard,
    ERC721,
    ERC721URIStorage,
    Ownable
{
    using Counters for Counters.Counter;
    Counters.Counter private tokenId;
    Counters.Counter private listedItemId;

    ///This struct describes the main NFT of a user
    struct UserToken {
        uint256 tokenId;
        string name;
        string symbol;
        address owner;
        address tokenAddress;
    }

    // structs for an item to be listed
    struct ListedItem {
        uint256 itemId;
        address payable fundingRecipient;
        uint256 price;
        uint32 quantity;
        uint32 numSold;
        uint32 royaltyBPS;
    }

    ///Mapping a user's address to the tokens created
    mapping(address => UserToken[]) private addressToTokens;
    //Mapping of items to a Item struct
    mapping(uint256 => ListedItem) public listedItems;
    ///Mapping an Item to the token copies minted from it.
    mapping(uint256 => uint256) public tokenToListedItem;
    // The amount of funds that have been earned from selling the copies of a given item.
    mapping(uint256 => uint256) public depositedForItem;
    // Total amount earned by Seller... mapping of address -> Amount earned
    mapping(address => uint256) private s_proceeds;
    // mapping(uint256 => uint256) public depositedForEdition;

    string private _platformName;

    // ================================
    // EVENTS
    // ================================

    ///Emitted when a Item is created
    event ItemCreated(
        uint256 indexed itemId,
        address payable fundingRecipient,
        uint256 price,
        uint32 quantity,
        uint32 royaltyBPS
    );

    ///Emitted when a new NFT is created
    event tokenCreated(
        uint256 indexed tokenId,
        string name,
        string symbol,
        address owner,
        address tokenAddress,
        string contractBaseURI
    );

    ///Emitted when a copy of an item is sold
    event itemCopySold(
        uint256 indexed soldItemCopyId,
        uint256 soldItemId,
        uint32 numSold,
        address buyer,
        string soldItemBaseURI
    );

    constructor() ERC721("Cloudax", "CLDX") {}

    /// @notice Creates a new NFT item.
    /// @param _fundingRecipient The account that will receive sales revenue.
    /// @param _price The price at which each copy of NFT item or token from a NFT item will be sold, in ETH.
    /// @param _quantity The maximum number of NFT item's copy or tokens that can be sold.
    /// @param _royaltyBPS The royalty amount in bps per copy of a NFT item.
    function createItem(
        address payable _fundingRecipient,
        uint256 _price,
        uint32 _quantity,
        uint32 _royaltyBPS //// onlyOwner
    ) external {
        // Validations
        if (_fundingRecipient == address(0)) {
            revert InvalidAddress();
        }

        // Check that the track's quantity is more than zero(0).
        // require(_quantity > 0, "Track quantity must not be less than 0");
        if (_quantity <= 0) {
            revert QuantityRequired({quantity: _quantity, minRequired: 1});
        }

        listedItemId.increment();
        uint256 newItemId = listedItemId.current();
        listedItems[newItemId] = ListedItem({
            itemId: newItemId,
            fundingRecipient: _fundingRecipient,
            price: _price,
            numSold: 0,
            quantity: _quantity,
            royaltyBPS: _royaltyBPS
        });

        emit ItemCreated(
            newItemId,
            _fundingRecipient,
            0,
            _quantity,
            _royaltyBPS
        );
    }

    /// @notice Creates a new NFT for a user
    /// @param _owner The address of the user that owns this NFT
    /// @param _name The name of this NFT
    /// @param _symbol The symbol of this NFT
    /// @param _contractBaseURI The address of the new NFT to be created for a user
    function createToken(
        address _owner,
        string memory _name,
        string memory _symbol,
        string memory _contractBaseURI
    ) external returns (bool) {
        // Spin up new ERC721 token contract for the user
        CloudaxNFT erc721 = new CloudaxNFT(
            _owner,
            _name,
            _symbol,
            _contractBaseURI
        );
        // erc721.initialize(_owner, _name, _symbol, _contractBaseURI);

        address _tokenAddress = address(erc721);

        // Save token data
        address sender = msg.sender;
        tokenId.increment();
        uint256 currentTokenId = tokenId.current();

        UserToken[] storage tokens = addressToTokens[sender];
        tokens.push(
            UserToken(currentTokenId, _name, _symbol, sender, _tokenAddress)
        );
        addressToTokens[sender] = tokens;
        // Emit and return
        emit tokenCreated(
            currentTokenId,
            _name,
            _symbol,
            sender,
            _tokenAddress,
            _contractBaseURI
        );

        return true;
    }

    /// @notice Creates or mints a new copy or token for the given item, and assigns it to the buyer
    /// @param _itemId The id of the item selected to be purchased
    function buyItemCopy(uint256 _itemId, string memory _tokenBaseURI)
        external
        payable
    {
        // Caching variables locally to reduce reads
        uint256 price = listedItems[_itemId].price;
        uint32 quantity = listedItems[_itemId].quantity;
        uint32 numSold = listedItems[_itemId].numSold;

        // Validations
        // Check that the item's quantity is more than zero(0).
        if (quantity <= 0) {
            revert QuantityDoesNotExist({availableQuantity: quantity});
        }
        // Check that the item's ID is not Zero(0).
        if (_itemId <= 0) {
            revert InvalidItemId({itemId: _itemId});
        }
        // Check that there are still some copies or tokens of the item that are available for purchase.
        if (quantity >= numSold) {
            revert ItemSoldOut({quantity: quantity, numSold: numSold});
        }
        // Check that the buyer approved an amount that is equal or more than the price of the item set by the seller.
        if (price > msg.value) {
            revert InsufficientFund({price: price, allowedFund: msg.value});
        }
        // Update the deposited total for the item.
        // Adding the newly earned money to the total amount a user has earned from an Item.
        depositedForItem[_itemId] += msg.value;

        // Increment the number of copies or tokens sold from this Item.
        listedItems[_itemId].numSold++;
        listedItemId.increment();
        uint256 newTokenId = listedItemId.current();

        // https://cloudaxnftmarketplace.xyz/metadata/[USER_ID]/[ITEM_ID]/[TOKEN_ID]
        // Where _tokenBaseURI = https://cloudaxnftmarketplace.xyz/metadata/[USER_ID]/[ITEM_ID]
        // Generating a metadata URL for the new copy of the ITEM or Token that was generated.

        _tokenBaseURI = string(
            abi.encodePacked(_tokenBaseURI, "/", Strings.toString(newTokenId))
        );

        // Mint a new copy or token from the Item for the buyer, using the `newTokenId`.
        safeMint(msg.sender, newTokenId, _tokenBaseURI);
        // Store the mapping of the ID a sold item's copy or token id to the Item being purchased.
        tokenToListedItem[newTokenId] = _itemId;

        emit itemCopySold(
            newTokenId,
            _itemId,
            listedItems[_itemId].numSold,
            msg.sender,
            _tokenBaseURI
        );
    }

    function safeMint(
        address _to,
        uint256 _tokenId,
        string memory _uri
    ) private {
        _safeMint(_to, _tokenId);
        _setTokenURI(_tokenId, _uri);
    }

    /// @notice Returns token metadata URI (metadata URL). e.g. https://cloudaxnftmarketplace.xyz/metadata/[USER_ID]/[ITEM_ID]
    function tokenURI(uint256 _tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        if (!_exists(_tokenId)) {
            revert InvalidItemId({itemId: _tokenId});
        }

        return super.tokenURI(_tokenId);
    }

    function getPlatformName() public view virtual returns (string memory) {
        return _platformName;
    }

    function _burn(uint256 _tokenId)
        internal
        override(ERC721, ERC721URIStorage)
        onlyOwner
    {
        super._burn(_tokenId);
    }
}