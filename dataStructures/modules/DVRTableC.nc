generic module DVRTableC(typedef t){
     provides interface DVRTable<t>;
}

implementation{

     uint8_t MAX_HOP = 18;

     typedef struct DVRtouple{
        uint8_t dest;
        uint8_t cost;
        uint8_t nextHop;
     }DVRtouple;

     DVRtouple table[19];

     command void DVRTable.initialize(){
          int i = 0;
          for(i = 0; i < 19; i++){
                  // TODO POTENTIAL BUG BUG BUG BUG BUG BUG BUG BUG BUG BUG
                  table[i].dest         = (uint8_t)NULL;
                  table[i].cost         = MAX_HOP;
                  table[i].nextHop      = (uint8_t)NULL;
          }
     }

     command void DVRTable.insert(uint8_t dest, uint8_t cost, uint8_t nextHop){
          //input data to a touple
          DVRtouple input = {dest, cost, nextHop};
     }

     command void DVRTable.remove(uint8_t dest){
          int i = 0;
             for(i = 0; i < 19; i++) {
                     if(table[i].dest  == dest) {
                             table[i].dest = (uint8_t)NULL;
                             table[i].cost = MAX_HOP;
                             table[i].nextHop = (uint8_t)NULL;

                     }
             }
     }

     command void DVRTable.clear(){
             int i = 0;
             DVRtouple temp = {(uint8_t)NULL, MAX_HOP, (uint8_t)NULL};
             for(i = 0; i < 19; i++)
                     table[i] = temp;
     }


}
