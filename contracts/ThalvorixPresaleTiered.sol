// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ThalvorixPresaleTiered
 * @notice Presale untuk token THX (Thalvorix) di BNB Chain, dengan cap diskon
 * per tier NFT (bukan flat per NFT).
 * - Harga normal: 1 BNB = 1.000.000 THX
 * - Holder Hero NFT: diskon 80% -> 1 BNB = 5.000.000 THX.
 * - Cap diskon (total THX harga diskon per wallet, dijumlah dari NFT yang
 *   dipegang DAN disertakan di transaksi buy):
 *   Common 7.500, Uncommon 8.000, Rare 10.000, Epic 50.000, Legendary 100.000 THX.
 *   (Common 7.500 = persis 1x pembelian minimal holder: 0,0015 BNB.)
 * - Pembeli menyertakan tokenId NFT-nya di buy(tokenIds). TokenId harus urut
 *   naik (unik) dan harus milik pembeli (dicek via ownerOf). Array kosong =
 *   beli harga NORMAL (tanpa diskon, tanpa cap) — jadi holder yang sudah
 *   habis kuota diskon tetap bisa lanjut beli harga normal.
 * - Min beli 0,0015 BNB (~$1), maks 5 BNB per transaksi.
 * - Setelah presale selesai, owner finalize: THX yang tidak terjual di-BURN,
 *   BNB ditarik owner.
 *
 * Hero contract tidak punya Enumerable (tidak ada tokenOfOwnerByIndex), jadi
 * kontrak ini TIDAK BISA menghitung sendiri NFT apa saja yang dimiliki
 * pembeli — daftar tokenId harus disertakan pembeli di transaksi (website
 * sudah tahu daftar NFT milik wallet dari scan event).
 * Tier dibaca on-chain via hero.rarityOf(tokenId):
 * 0 Common, 1 Uncommon, 2 Rare, 3 Epic, 4 Legendary.
 *
 * Token THX: 0x4fCdA9835B50BDF454BA96a813d564Ad3060c540 (1.000.000.000 THX, 18 desimal)
 * Hero NFT:  0x6D862c8B847323961FCD349ffFbee0133F6B929A
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IHero {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function rarityOf(uint256 tokenId) external view returns (uint8);
}

contract ThalvorixPresaleTiered {
    IERC20 public immutable thx;
    IHero public immutable hero;
    address public immutable dead = 0x000000000000000000000000000000000000dEaD;

    address public owner;

    // ---- Harga (THX per 1 BNB, THX memakai 18 desimal) ----
    uint256 public constant RATE = 1_000_000 * 1e18;      // normal: 1 BNB = 1.000.000 THX
    uint256 public constant NFT_RATE = 5_000_000 * 1e18;  // holder NFT (diskon 80%): 1 BNB = 5.000.000 THX

    // ---- Batas beli ----
    uint256 public constant MIN_BUY = 0.0015 ether;       // min beli 0,0015 BNB (~$1)
    uint256 public constant MAX_BUY = 5 ether;            // maks beli 5 BNB per transaksi

    // ---- Jadwal ----
    uint256 public startTime;
    uint256 public endTime;
    bool public finalized;

    uint256 public totalRaised; // total BNB masuk (wei)
    uint256 public totalSold;   // total THX terjual (wei THX)

    // THX yang sudah dibeli tiap wallet di harga diskon (kumulatif, untuk enforcing cap tier).
    mapping(address => uint256) public nftDiscountBought;

    event Bought(address indexed buyer, uint256 bnbAmount, uint256 thxAmount, bool discounted);
    event Finalized(uint256 unsoldBurned, uint256 bnbWithdrawn);
    event TimesSet(uint256 startTime, uint256 endTime);

    modifier onlyOwner() {
        require(msg.sender == owner, "bukan owner");
        _;
    }

    constructor(
        address _thx,
        address _hero,
        uint256 _startTime,
        uint256 _endTime
    ) {
        require(_thx != address(0) && _hero != address(0), "alamat nol");
        require(_endTime > _startTime, "end harus > start");
        thx = IERC20(_thx);
        hero = IHero(_hero);
        owner = msg.sender;
        startTime = _startTime;
        endTime = _endTime;
    }

    function setTimes(uint256 _startTime, uint256 _endTime) external onlyOwner {
        require(!finalized, "sudah finalize");
        require(_endTime > _startTime, "end harus > start");
        startTime = _startTime;
        endTime = _endTime;
        emit TimesSet(_startTime, _endTime);
    }

    function isNftHolder(address user) public view returns (bool) {
        return hero.balanceOf(user) > 0;
    }

    /// @notice Cap diskon per 1 NFT menurut tier-nya (dalam THX, 18 desimal).
    /// 0 Common 7.500, 1 Uncommon 8.000, 2 Rare 10.000, 3 Epic 50.000, 4 Legendary 100.000.
    /// Common 7.500 = persis 1x pembelian minimal holder (0,0015 BNB).
    function tierCap(uint8 rarity) public pure returns (uint256) {
        if (rarity == 0) return 7500 * 1e18;
        if (rarity == 1) return 8000 * 1e18;
        if (rarity == 2) return 10000 * 1e18;
        if (rarity == 3) return 50000 * 1e18;
        return 100000 * 1e18; // 4 Legendary
    }

    /// @notice Total cap diskon untuk daftar tokenId (harus milik `user`,
    /// harus urut naik supaya tiap token hanya dihitung sekali).
    function discountCapOf(address user, uint256[] calldata tokenIds) public view returns (uint256 totalCap) {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (i > 0) require(tokenIds[i] > tokenIds[i - 1], "tokenIds harus urut & unik");
            require(hero.ownerOf(tokenIds[i]) == user, "bukan pemilik NFT");
            totalCap += tierCap(hero.rarityOf(tokenIds[i]));
        }
    }

    /// @param tokenIds Daftar tokenId Hero NFT milik pembeli (urut naik, unik).
    /// Array kosong = beli harga NORMAL tanpa diskon dan tanpa cap.
    function buy(uint256[] calldata tokenIds) external payable {
        require(block.timestamp >= startTime, "presale belum mulai");
        require(block.timestamp <= endTime, "presale sudah selesai");
        require(!finalized, "sudah finalize");
        require(msg.value >= MIN_BUY, "min 0,0015 BNB");
        require(msg.value <= MAX_BUY, "maks 5 BNB per transaksi");

        bool discounted = tokenIds.length > 0;
        uint256 rate = discounted ? NFT_RATE : RATE;
        uint256 thxAmount = (msg.value * rate) / 1 ether;
        require(thxAmount > 0, "jumlah THX nol");

        if (discounted) {
            uint256 maxDiscounted = discountCapOf(msg.sender, tokenIds);
            require(
                nftDiscountBought[msg.sender] + thxAmount <= maxDiscounted,
                "melebihi batas diskon tier NFT"
            );
            nftDiscountBought[msg.sender] += thxAmount;
        }

        require(
            thx.balanceOf(address(this)) >= thxAmount,
            "stok THX presale habis"
        );

        totalRaised += msg.value;
        totalSold += thxAmount;

        require(thx.transfer(msg.sender, thxAmount), "transfer THX gagal");
        emit Bought(msg.sender, msg.value, thxAmount, discounted);
    }

    /**
     * @notice Dipanggil owner setelah presale selesai.
     * THX yang tidak terjual dikirim ke dead address (BURN).
     * BNB hasil presale ditarik ke owner (untuk dibuat likuiditas + operasional).
     */
    function finalize() external onlyOwner {
        require(block.timestamp > endTime, "presale belum selesai");
        require(!finalized, "sudah finalize");
        finalized = true;

        uint256 unsold = thx.balanceOf(address(this));
        uint256 bnbBalance = address(this).balance;

        if (unsold > 0) {
            require(thx.transfer(dead, unsold), "burn gagal");
        }
        if (bnbBalance > 0) {
            (bool ok, ) = payable(owner).call{value: bnbBalance}("");
            require(ok, "withdraw BNB gagal");
        }
        emit Finalized(unsold, bnbBalance);
    }

    // Terima BNB (untuk buy()).
    receive() external payable {
        // Biarkan buy() yang menangani; receive kosong supaya transfer BNB langsung tidak nyangkut tanpa THX.
        revert("gunakan buy()");
    }

    function withdrawStuckThx() external onlyOwner {
        // Darurat: hanya setelah finalize, kalau ada THX nyangkut (seharusnya sudah 0 karena burn).
        require(finalized, "belum finalize");
        uint256 bal = thx.balanceOf(address(this));
        if (bal > 0) require(thx.transfer(owner, bal), "gagal");
    }
}
