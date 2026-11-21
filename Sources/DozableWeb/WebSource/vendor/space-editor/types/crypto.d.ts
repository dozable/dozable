export declare function sha256Hex(text: string): string;
export declare function createHash(alg: string): {
    update(s: string): /*elided*/ any;
    digest(_enc: 'hex'): string;
};
declare const _default: {
    createHash: typeof createHash;
};
export default _default;
