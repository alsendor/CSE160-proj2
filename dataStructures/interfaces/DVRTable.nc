interface DVRTable<t>{
     command void initialize();
     command void insert(uint8_t dest, uint8_t cost, uint8_t nextHop);
     command void remove(uint8_t dest);
     command void clear();
}
