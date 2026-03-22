pragma solidity 0.8.24;

interface ITokenWhitelist {
    function addToken(address token) external;
    function removeToken(address token) external;

    function isWhitelisted(address token) external view returns (bool);
    function getWhitelistedTokens() external view returns (address[] memory tokens);
}
